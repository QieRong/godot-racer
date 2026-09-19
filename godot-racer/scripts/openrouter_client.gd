extends Node
## OpenRouter / LLM 测试接口（**可选增强，游戏不依赖它**）。
##
## 实测状态（2026-09，本机）：走本地代理 http://127.0.0.1:7892 时
## `--check=openrouter` 返回 HTTP 200、"PONG"，延迟约 7~8 秒。
## 两个踩过的坑记在这里，免得后人重踩：
##   ① Godot 的 HTTPRequest 用自带 mbedTLS，**不走 Windows schannel**，
##      所以命令行 `curl` 报 `SEC_E_NO_CREDENTIALS` 时 Godot 反而能通；
##      排查网络别拿 curl 的结果直接下结论（同目录有 `ERROR: Failed to read the root
##      certificate store` 的日志，那是引擎读系统证书库的告警，不影响本次请求）。
##   ② 出口是被封的，**必须**挂代理；本模块只给这一个 HTTPRequest 挂，
##      不碰系统代理、不开 TUN，避免连累 DSH 等本地服务。
##
## 配置读取顺序（**密钥绝不入库**，三层兜底）：
##   1) 环境变量（最推荐，游戏进程之外）
##        $env:OPENROUTER_API_KEY = "sk-or-v1-..."
##        $env:OPENROUTER_PROXY   = "http://127.0.0.1:7892"   # 可选：只给本模块挂代理
##        $env:OPENROUTER_TIMEOUT = "45"                      # 可选：秒
##   2) 工程根的 `openrouter.local.cfg`（已在 .gitignore 里排除；可复制
##      `openrouter.cfg.example` 改名得到）
##   3) 打包后的 `user://openrouter.cfg`（导出后 res:// 只读，用这个）
##
## 用法：
##   var ai := OpenRouterClient.new()
##   add_child(ai)
##   var cases := await ai.generate_test_cases(50)   # 失败返回 []，调用方走本地确定性测试
##
## 设计要点：
##   - **不阻塞游戏**：所有调用都是 await 协程，失败/超时都返回空结果，绝不抛异常打断；
##   - **不做逐帧驾驶**：免费额度下延迟几秒，逐帧调 API 让 AI 开车既不可复现也无法
##     用来发现物理 bug。AI 只用来 ① 生成测试用例参数 ② 归因失败日志；
##   - 真正的压测是本地确定性的（见 ai_test_driver.gd），断网也照跑。

## 默认模型（免费档 NVIDIA Nemotron。换模型只改这里或配置文件）
const DEFAULT_MODEL := "nvidia/nemotron-3-ultra-550b-a55b:free"
## 备用轻量模型：默认模型响应过慢/不可用时自动切换。
##
## **这个值是用 `--check=models` 探活查出来的，不是猜的**（2026-09 实测）：
##   - AGENTS.md 原先指定的 `meta-llama/llama-3.1-8b-instruct:free` 已从模型目录下架，
##     调用返回 HTTP 404 —— 一个消失的备用模型等于没有备用，主模型一超时就直接降级；
##   - 当前目录里 22 个免费模型，探活前 5 个全部 HTTP 200；
##   - 其中 `nex-agi/nex-n2.5-mini:free` 最快（1.5s），故选它做备用。
## 模型会下架，所以隔一段时间请重跑 `--check=models` 复核这个值。
const FALLBACK_MODEL := "nex-agi/nex-n2.5-mini:free"
const ENDPOINT := "https://openrouter.ai/api/v1/chat/completions"
## 模型目录接口：用来**查证**某个免费模型还在不在，而不是靠记忆写死模型名。
## 踩过的坑：`meta-llama/llama-3.1-8b-instruct:free` 曾经可用，现在返回 HTTP 404
## （模型已下架）。所以备用模型不能靠猜，必须先探活。
const MODELS_ENDPOINT := "https://openrouter.ai/api/v1/models"
## 单次请求超时（秒）。**可配置**，不写死 —— AGENTS.md 建议 1.0 秒，
## 但免费档大模型首字延迟经常 3~15 秒，1 秒会 100% 假超时，所以默认给 45 秒。
## 可用 环境变量 OPENROUTER_TIMEOUT / cfg 里的 timeout= 覆盖。
const DEFAULT_TIMEOUT_SEC := 45.0
## 响应超过这个时长就认为"太慢"，下次自动换 FALLBACK_MODEL
const SLOW_RESPONSE_SEC := 20.0

## 密钥来源（只读环境变量或 user:// 配置，代码里不留任何字面量）
var api_key := ""
## HTTP 代理（智能分流时只影响本模块，不影响游戏其它部分）
var proxy_url := ""
## 当前使用的模型 id（连续超时/限流后会自动切到 fallback_model）
var model := DEFAULT_MODEL
## 备用模型
var fallback_model := FALLBACK_MODEL
## 单次请求超时（秒），可配置
var request_timeout_sec := DEFAULT_TIMEOUT_SEC
## 是否可用（没 key 就是 false，调用方据此走本地降级路径）
var available := false
## 最近一次错误（诊断用，**绝不包含密钥**）
var last_error := ""
## 最近一次是否因 429/401 而降级
var degraded := false
## 降级原因（供日志打印）
var degrade_reason := ""

var _http: HTTPRequest = null
## 用自增序号作废过期请求：每次请求前 +1，回调里发现序号变了就丢弃结果。
## 这样即使旧连接还在后台，也不会和本次请求的响应混在一起。
var _req_serial := 0
## 最近一次请求的完成结果（由回调填充，_await_response 消费）
var _pending := {}
var _pending_done := false
## 最近一次模型响应的 finish_reason（"length" 表示被 max_tokens 截断）
var _last_finish_reason := ""


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_load_config()
	# 引擎自身超时留一点余量（真正的截止时间在 _await_response 里判）
	_http.timeout = maxf(request_timeout_sec + 5.0, 10.0)
	print("[OpenRouter] 状态：%s%s%s" % [
		"可用（模型 %s）" % model if available else "未配置（将使用本地确定性测试）",
		"" if proxy_url.is_empty() else "  代理=%s" % proxy_url,
		"  超时=%.0fs" % request_timeout_sec,
	])
	if not available:
		last_error = "没有 API key（设置 OPENROUTER_API_KEY，或写进 openrouter.local.cfg）"


func _load_config() -> void:
	api_key = OS.get_environment("OPENROUTER_API_KEY")
	proxy_url = OS.get_environment("OPENROUTER_PROXY")
	var model_env := OS.get_environment("OPENROUTER_MODEL")
	if not model_env.is_empty():
		model = model_env
	var timeout_env := OS.get_environment("OPENROUTER_TIMEOUT")
	if not timeout_env.is_empty():
		request_timeout_sec = maxf(1.0, float(timeout_env))
	# 兜底 1：工程根的本地配置（.gitignore 已排除，不会入库）
	if api_key.is_empty() and FileAccess.file_exists("res://openrouter.local.cfg"):
		_parse_cfg("res://openrouter.local.cfg")
	# 兜底 2：导出后的 user:// 配置
	if api_key.is_empty() and FileAccess.file_exists("user://openrouter.cfg"):
		_parse_cfg("user://openrouter.cfg")
	# 即使 key 来自环境变量，也再扫一遍本地配置把 proxy/timeout 补上
	if FileAccess.file_exists("res://openrouter.local.cfg"):
		_parse_cfg("res://openrouter.local.cfg")
	if not proxy_url.is_empty():
		_apply_proxy()
	available = not api_key.is_empty()


## 解析 `key=value` 形式的配置文件（每行一条，支持 # 注释）
func _parse_cfg(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#") or not line.contains("="):
			continue
		var parts := line.split("=", true, 1)
		var k := parts[0].strip_edges().to_lower()
		var v := parts[1].strip_edges()
		match k:
			"api_key", "api-key":
				if api_key.is_empty():
					api_key = v
			"proxy":
				if proxy_url.is_empty():
					proxy_url = v
			"model":
				model = v
			"fallback_model":
				fallback_model = v
			"timeout":
				request_timeout_sec = maxf(1.0, float(v))


## 应用代理。智能分流的关键：**只给这一个 HTTPRequest 挂代理**，
## 游戏其它网络行为（以及 DSH 本身）完全不受影响。
func _apply_proxy() -> void:
	if _http == null:
		return
	var u := proxy_url
	u = u.replace("http://", "").replace("https://", "").replace("socks5://", "")
	var parts := u.split(":")
	var host := parts[0]
	var port := 8080
	if parts.size() > 1:
		port = int(parts[1])
	# 注意：Godot 4.4 的 set_http_proxy 只接受 (host, port) **两个**参数，
	# 多传第三个（用户名）会直接解析错误、把整个依赖它的脚本连坐编译失败。
	_http.set_http_proxy(host, port)
	print("[OpenRouter] 已为测试模块单独配置代理 %s:%d（只影响本模块，不影响游戏与其它进程）" % [host, port])


## 连通性自检：发一条最小请求，**分层报告**失败原因。
## 返回 {"ok": bool, "detail": String, "raw": String}
##
## 为什么要分层：连不上可能是"代理没起""代理不通""key 无效""模型名错"四件事之一，
## 只报一句"失败"没法排查。这里把 HTTPRequest 的 result 码也翻译成人话。
func test_connection() -> Dictionary:
	if api_key.is_empty():
		return {"ok": false, "detail": "没有 API key：请创建 res://openrouter.local.cfg 填 api_key=…，"
			+ "或设环境变量 OPENROUTER_API_KEY", "raw": ""}
	if _http == null:
		return {"ok": false, "detail": "HTTPRequest 未就绪（节点还没进树？）", "raw": ""}
	# 复用 _post_chat / _await_response：这样探针也走"带 deadline、不阻塞主循环"的同一条路径，
	# 不会出现"测试能跑但正式调用会挂死"的口径不一致。
	var messages := [
		{"role": "system", "content": "你是测试探针，只回答一个词。"},
		{"role": "user", "content": "回复：PONG"},
	]
	var r := await _post_chat(messages, model)
	var result_code := int(r.get("result", -1))
	var http_code := int(r.get("code", 0))
	var raw := str(r.get("raw", ""))
	if bool(r.get("timeout", false)):
		return {"ok": false, "raw": raw, "detail":
			"超时（%.0f 秒）。请求在代理/出口处卡住了。" % request_timeout_sec}
	match result_code:
		HTTPRequest.RESULT_SUCCESS:
			pass
		HTTPRequest.RESULT_CANT_CONNECT:
			return {"ok": false, "raw": raw, "detail":
				"连不上（RESULT_CANT_CONNECT）。代理没启动、端口不对，或节点不可用。"}
		HTTPRequest.RESULT_CANT_RESOLVE:
			return {"ok": false, "raw": raw, "detail":
				"DNS 解析失败（RESULT_CANT_RESOLVE）。若用了代理，多半是代理没有做远端解析。"}
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return {"ok": false, "raw": raw, "detail":
				"连接被中断（RESULT_CONNECTION_ERROR）。常见于 TLS 被中间人拦、或代理不支持 HTTPS 隧道。"}
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return {"ok": false, "raw": raw, "detail":
				"TLS 握手失败（RESULT_TLS_HANDSHAKE_ERROR）。证书链不被信任，或中间人在改包。"}
		_:
			return {"ok": false, "raw": raw, "detail":
				str(r.get("error", "网络层失败，result=%d" % result_code))}
	match http_code:
		200:
			var parsed = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_DICTIONARY and parsed.has("choices"):
				var choices: Array = parsed["choices"]
				if not choices.is_empty():
					var content: String = str((choices[0] as Dictionary).get("message", {}).get("content", ""))
					var usage := ""
					if parsed.has("usage"):
						usage = "（tokens: %s）" % str(parsed["usage"])
					return {"ok": true, "raw": raw, "detail": "HTTP 200，模型回复：%s %s" % [content.strip_edges(), usage]}
			return {"ok": false, "raw": raw, "detail": "HTTP 200 但返回体结构不对"}
		401:
			return {"ok": false, "raw": raw, "detail": "HTTP 401 未授权：key 无效或已删除"}
		404:
			return {"ok": false, "raw": raw, "detail": "HTTP 404：模型名不存在（检查拼写，:free 后缀要带上）"}
		429:
			return {"ok": false, "raw": raw, "detail": "HTTP 429：限流或免费额度用尽"}
		402:
			return {"ok": false, "raw": raw, "detail": "HTTP 402：需要付费额度（该模型可能不是免费的）"}
		_:
			return {"ok": false, "raw": raw, "detail": "HTTP %d" % http_code}


## 发一次请求并等响应：**带自己的截止时间，绝不阻塞主循环**。
##
## 返回 {"ok": bool, "code": int, "result": int, "raw": String, "elapsed": float}
##
## 为什么不能只靠 HTTPRequest.timeout：
##   1) 它只是引擎层兜底，超时后回调不一定按时到达；
##   2) 没有它的话 `await request_completed` 在网络半死时**永远不返回**，
##      调用方的协程就永久挂住（这就是"卡住游戏"的来源）。
## 这里用"协程 + 每帧轮询 + 自己的 deadline"实现：超时立刻放弃本次请求并作废它的响应，
## 期间每帧 yield 一次，主循环照常跑（物理/渲染/输入都不受影响）。
func _await_response(serial: int, timeout_sec: float = -1.0) -> Dictionary:
	var limit := request_timeout_sec if timeout_sec <= 0.0 else timeout_sec
	var t0 := Time.get_ticks_msec() / 1000.0
	while true:
		if _req_serial != serial:
			# 已被新请求作废（或本请求已完成并消费）
			return {"ok": false, "code": 0, "result": -1, "raw": "", "elapsed": 0.0, "stale": true}
		if _pending_done:
			_pending_done = false
			return _pending
		var elapsed := Time.get_ticks_msec() / 1000.0 - t0
		if elapsed >= limit:
			# 超时：作废本次，避免迟到的响应污染下一次请求
			_req_serial += 1
			_http.cancel_request()
			return {"ok": false, "code": 0, "result": HTTPRequest.RESULT_TIMEOUT, "raw": "",
					"elapsed": elapsed, "timeout": true, "limit": limit}
		await get_tree().process_frame
	return {"ok": false, "code": 0, "result": -1, "raw": "", "elapsed": 0.0}


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_pending = {
		"ok": result == HTTPRequest.RESULT_SUCCESS and code == 200,
		"code": code,
		"result": result,
		"raw": body.get_string_from_utf8(),
		"elapsed": 0.0,
	}
	_pending_done = true


## 发一次 POST 并返回解析结果。所有失败路径都**只返回错误、不抛异常、不阻塞**。
## max_tokens 可调：生成测试用例时输出很长，给太小会被**从中间截断**成非法 JSON
## （实测 12 组用例 + max_tokens=1200 → `Parse JSON failed: Unterminated string`）。
func _post_chat(messages: Array, model_id: String, max_tokens: int = 1200, timeout_sec: float = -1.0) -> Dictionary:
	if api_key.is_empty():
		return {"ok": false, "code": 0, "result": -1, "raw": "", "error": "没有 API key"}
	var body := {
		"model": model_id,
		"messages": messages,
		"temperature": 0.8,
		"max_tokens": max_tokens,
	}
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % api_key,
		"Content-Type: application/json",
		"HTTP-Referer: http://127.0.0.1",
		"X-Title: godot-racer-test",
	])
	_req_serial += 1
	var serial := _req_serial
	_pending_done = false
	var err := _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		return {"ok": false, "code": 0, "result": err, "raw": "",
				"error": "request() 立即失败，错误码 %d（%s）" % [err, error_string(err)]}
	return await _await_response(serial, timeout_sec)


## 归因/生成共用的入口：自动处理模型回退与降级。返回文本（失败返回 ""）。
func _call_model(system_prompt: String, user_prompt: String, max_tokens: int = 1200, timeout_sec: float = -1.0) -> String:
	if not available:
		last_error = "没有 API key（设置 OPENROUTER_API_KEY 或写进 openrouter.local.cfg）"
		degraded = true
		degrade_reason = "无密钥"
		return ""
	_last_finish_reason = ""
	var messages := [
		{"role": "system", "content": system_prompt},
		{"role": "user", "content": user_prompt},
	]
	var t0 := Time.get_ticks_msec() / 1000.0
	var r := await _post_chat(messages, model, max_tokens, timeout_sec)
	var elapsed := Time.get_ticks_msec() / 1000.0 - t0
	# 429 / 401 / 402：立刻降级，绝不重试拖时间
	if not bool(r.get("ok", false)):
		var code := int(r.get("code", 0))
		var res := int(r.get("result", -1))
		if code == 429 or code == 401 or code == 402:
			degraded = true
			degrade_reason = "HTTP %d" % code
			last_error = {
				429: "HTTP 429 限流/免费额度用尽",
				401: "HTTP 401 密钥无效",
				402: "HTTP 402 需要付费额度",
			}.get(code, "HTTP %d" % code)
			printerr("[OpenRouter] %s → 立即降级为本地确定性测试（不重试、不阻塞）" % last_error)
			available = false
			return ""
		if res == HTTPRequest.RESULT_TIMEOUT or bool(r.get("timeout", false)):
			last_error = "请求超时（%.0f 秒，可用 OPENROUTER_TIMEOUT 或 cfg 的 timeout= 调整）" % float(r.get("limit", request_timeout_sec))
			printerr("[OpenRouter] %s" % last_error)
			# 超时不降级，但换轻量模型再试一次（免费档大模型经常慢）
			if model != fallback_model:
				print("[OpenRouter] 换用轻量模型重试一次：%s" % fallback_model)
				model = fallback_model
				return await _call_model(system_prompt, user_prompt, max_tokens, timeout_sec)
			return ""
		last_error = str(r.get("error", "HTTP %d / result=%d" % [code, res]))
		printerr("[OpenRouter] 请求失败：%s" % last_error)
		return ""
	# 成功：记录耗时，过慢则下次换轻量模型
	if elapsed > SLOW_RESPONSE_SEC and model != fallback_model:
		print("[OpenRouter] 本次响应 %.1fs（超过 %.0fs），后续改用轻量模型 %s"
			% [elapsed, SLOW_RESPONSE_SEC, fallback_model])
		model = fallback_model
	var parsed = JSON.parse_string(str(r.get("raw", "")))
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("choices"):
		last_error = "返回体不是预期结构"
		return ""
	var choices: Array = parsed["choices"]
	if choices.is_empty():
		last_error = "choices 为空"
		return ""
	var first: Dictionary = choices[0]
	_last_finish_reason = str(first.get("finish_reason", ""))
	if _last_finish_reason == "length":
		# 被 max_tokens 截断了：这一次的文本很可能不是合法 JSON。
		# 不在这里报错（调用方会用 _salvage_json_array 尽力抢救），但留下证据。
		print("[OpenRouter] 注意：响应被 max_tokens=%d 截断（finish_reason=length）" % max_tokens)
	print("[OpenRouter] 请求成功：模型=%s 耗时=%.1fs finish=%s"
		% [model, elapsed, _last_finish_reason if not _last_finish_reason.is_empty() else "?"])
	return str((first as Dictionary).get("message", {}).get("content", ""))


## 让 AI 生成 N 组**极端测试用例**（位置/速度/朝向/天气）。
## 返回空数组表示不可用 —— 调用方应回退到本地确定性随机（固定种子）。
##
## 为什么把"生成用例"交给 AI：这块本来就是"想不全面"的问题（人手写容易漏边界），
## 而生成结果是可以**落盘复查**的，不依赖运行时网络。
func generate_test_cases(count: int, track_hint: String = "") -> Array:
	if not available:
		return []
	var sys := "你是赛车游戏物理测试工程师。只输出 JSON 数组，不要任何解释、不要 markdown 代码块。"
	var usr := """为下面的赛道生成 %d 组极端测试用例，每组是一个对象：
{"pos": [x,y,z], "speed_mps": 数值, "heading_deg": 数值, "weather": "clear|rain|snow|sand", "note": "不超过 15 字的理由"}
要求覆盖：贴墙低速、贴墙高速、赛道外 5~50m、空中落下、正对墙、倒车撞墙、S 弯切内线。
每条 note 必须短（15 字以内），保证整个数组不被输出长度限制截断。
赛道信息：%s
只输出 JSON 数组。""" % [count, track_hint]
	# max_tokens 给足：用例 JSON 很长，太小会被**从中间截断**（实测 1200 → 非法 JSON）。
	# 但输出变长 → 耗时也变长：实测主模型 4096 token 输出会超过默认 45 秒，
	# 所以这里单独把这次调用的截止时间放宽到 90 秒（仍是**有界**的，不会挂死）。
	# 万一还是超时，会自动切到探活验证过的快速备用模型再试一次。
	var text := await _call_model(sys, usr, 3000, maxf(request_timeout_sec, 90.0))
	if text.is_empty():
		return []
	var cleaned := _strip_code_fence(text)
	var parsed = JSON.parse_string(cleaned)
	if typeof(parsed) == TYPE_ARRAY:
		print("[OpenRouter] AI 生成了 %d 组测试用例（模型 %s）" % [(parsed as Array).size(), model])
		return parsed
	# 截断救援：模型被 max_tokens 切断时整个数组不合法，但**前面完整的对象**还能用。
	# 与其整批丢弃退回本地随机，不如把能救的那几组救下来（这是免费档最常见的失败形态）。
	var salvaged := _salvage_json_array(cleaned)
	if not salvaged.is_empty():
		print("[OpenRouter] 响应不是合法 JSON 数组（%s），已从截断文本中抢救出 %d 组可用用例"
			% [last_error if not last_error.is_empty() else "解析失败", salvaged.size()])
		return salvaged
	last_error = "测试用例不是 JSON 数组（也没能抢救出完整对象）"
	print("[OpenRouter] %s" % last_error)
	return []


## 从（可能被截断的）文本里逐个大括号地抢救出完整的 JSON 对象。
## 做法：找出所有顶层的 `{...}`（按花括号配对，且跳过字符串里的括号），逐个独立解析；
## 谁解析成功就留下谁。这样即使最后一个对象被切断，前面的用例依然可用。
func _salvage_json_array(s: String) -> Array:
	var out: Array = []
	var depth := 0
	var start := -1
	var in_str := false
	var escaped := false
	for i in s.length():
		var ch := s[i]
		if in_str:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == "\"":
				in_str = false
			continue
		match ch:
			"\"":
				in_str = true
			"{":
				if depth == 0:
					start = i
				depth += 1
			"}":
				if depth > 0:
					depth -= 1
					if depth == 0 and start >= 0:
						var piece := s.substr(start, i - start + 1)
						var obj = JSON.parse_string(piece)
						if typeof(obj) == TYPE_DICTIONARY:
							out.append(obj)
						start = -1
	return out


## 让 AI 对一段失败日志做归因（可选，人工排查的辅助）
func diagnose(failure_log: String) -> String:
	if not available:
		return ""
	var sys := "你是物理引擎调试专家，回答用中文，不超过 150 字，直接给最可能的原因和建议的验证方法。"
	return await _call_model(sys, "下面是赛车游戏的一次失败记录，请归因：\n%s" % failure_log)


## 去掉模型偶尔包上的 ```json 代码块围栏
func _strip_code_fence(s: String) -> String:
	var t := s.strip_edges()
	if t.begins_with("```"):
		var first_nl := t.find("\n")
		if first_nl >= 0:
			t = t.substr(first_nl + 1)
		var end_fence := t.rfind("```")
		if end_fence >= 0:
			t = t.substr(0, end_fence)
	return t.strip_edges()


# ---------------------------------------------------------------------------
# 模型目录 / 探活：**用接口返回的事实决定用哪个模型**，不靠记忆写死。
# ---------------------------------------------------------------------------

## GET 模型目录，返回 id 以 `:free` 结尾的模型 id 列表（失败返回空数组）。
func list_free_models() -> Array:
	if api_key.is_empty():
		last_error = "没有 API key"
		return []
	if _http == null:
		last_error = "HTTPRequest 未就绪"
		return []
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % api_key,
		"Content-Type: application/json",
	])
	_req_serial += 1
	var serial := _req_serial
	_pending_done = false
	var err := _http.request(MODELS_ENDPOINT, headers, HTTPClient.METHOD_GET)
	if err != OK:
		last_error = "request() 立即失败，错误码 %d" % err
		return []
	var r: Dictionary = await _await_response(serial, maxf(request_timeout_sec, 60.0))
	if not bool(r.get("ok", false)):
		last_error = "拉取模型目录失败：HTTP %d / result=%d" % [int(r.get("code", 0)), int(r.get("result", -1))]
		return []
	var parsed = JSON.parse_string(str(r.get("raw", "")))
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("data"):
		last_error = "模型目录结构不是预期"
		return []
	var ids: Array = []
	for m in (parsed as Dictionary)["data"]:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var id := str((m as Dictionary).get("id", ""))
		if id.ends_with(":free"):
			ids.append(id)
	return ids


## 探活：对候选模型各发一条最小请求，返回 [{"model": id, "ok": bool, "code": int, "elapsed": float}]。
## 只探前 max_probe 个，避免把免费额度一次跑光。
func probe_models(candidates: Array, max_probe: int = 5) -> Array:
	var out: Array = []
	var n := 0
	for c in candidates:
		if n >= max_probe:
			break
		n += 1
		var id := str(c)
		if id == model:
			continue
		var t0 := Time.get_ticks_msec() / 1000.0
		var r: Dictionary = await _post_chat([
			{"role": "user", "content": "只回复两个字：可用"},
		], id, 24, 30.0)
		var elapsed := Time.get_ticks_msec() / 1000.0 - t0
		var ok := bool(r.get("ok", false)) and int(r.get("code", 0)) == 200
		out.append({"model": id, "ok": ok, "code": int(r.get("code", 0)),
			"result": int(r.get("result", -1)), "elapsed": elapsed})
		print("[OpenRouter] 探活 %s → %s（%.1fs，HTTP %d）"
			% [id, "可用" if ok else "不可用", elapsed, int(r.get("code", 0))])
	return out
