extends Node
## OpenRouter / LLM 测试接口（**预留实现，当前默认不联网**）。
##
## 为什么默认关闭：这台机器上 api.openrouter.ai 的真实出口被封（只有被 Watt Toolkit
## 劫持的域名能通），2026-09 实测 `curl` 直连与代理均失败。所以这里只把**接口与降级
## 路径**写好，等网络可用时改配置即可启用，不需要改任何游戏逻辑。
##
## 配置读取顺序（**密钥绝不入库**，三层兜底）：
##   1) 环境变量（最推荐，游戏进程之外）
##        $env:OPENROUTER_API_KEY = "sk-or-v1-..."
##        $env:OPENROUTER_PROXY   = "http://127.0.0.1:7897"   # 可选：只给本模块挂代理
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

## 默认模型（NVIDIA Nemotron 系列，免费额度可用；换模型只改这里）
const DEFAULT_MODEL := "nvidia/llama-3.1-nemotron-70b-instruct"
const ENDPOINT := "https://openrouter.ai/api/v1/chat/completions"
const TIMEOUT_SEC := 45.0

## 密钥来源（只读环境变量或 user:// 配置，代码里不留任何字面量）
var api_key := ""
## HTTP 代理（智能分流时只影响本模块，不影响游戏其它部分）
var proxy_url := ""
## 模型 id
var model := DEFAULT_MODEL
## 是否可用（没 key 就是 false，调用方据此走本地降级路径）
var available := false
## 最近一次错误（诊断用）
var last_error := ""

var _http: HTTPRequest = null


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_SEC
	add_child(_http)
	_load_config()
	print("[OpenRouter] 状态：%s%s" % [
		"可用（模型 %s）" % model if available else "未配置（将使用本地确定性测试）",
		"" if proxy_url.is_empty() else "  代理=%s" % proxy_url,
	])


func _load_config() -> void:
	api_key = OS.get_environment("OPENROUTER_API_KEY")
	proxy_url = OS.get_environment("OPENROUTER_PROXY")
	var model_env := OS.get_environment("OPENROUTER_MODEL")
	if not model_env.is_empty():
		model = model_env
	# 兜底 1：工程根的本地配置（.gitignore 已排除，不会入库）
	if api_key.is_empty() and FileAccess.file_exists("res://openrouter.local.cfg"):
		_parse_cfg("res://openrouter.local.cfg")
	# 兜底 2：导出后的 user:// 配置
	if api_key.is_empty() and FileAccess.file_exists("user://openrouter.cfg"):
		_parse_cfg("user://openrouter.cfg")
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


## 向模型发一次对话请求，返回解析后的文本（失败返回 ""）。
func chat(system_prompt: String, user_prompt: String) -> String:
	if not available:
		last_error = "没有 API key（设置 OPENROUTER_API_KEY 环境变量，或在 user://openrouter.cfg 里写 api_key=...）"
		return ""
	if _http == null:
		last_error = "HTTPRequest 未就绪"
		return ""
	var body := {
		"model": model,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_prompt},
		],
		"temperature": 0.8,
		"max_tokens": 1200,
	}
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % api_key,
		"Content-Type: application/json",
	])
	var err := _http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		last_error = "request() 失败，错误码 %d" % err
		return ""
	var res: Array = await _http.request_completed
	var result_code: int = res[0]
	var http_code: int = res[1]
	var payload: PackedByteArray = res[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		last_error = "网络层失败（result=%d；代理没开或出口被封时就是这种）" % result_code
		print("[OpenRouter] %s" % last_error)
		return ""
	if http_code != 200:
		last_error = "HTTP %d：%s" % [http_code, payload.get_string_from_utf8().substr(0, 200)]
		print("[OpenRouter] %s" % last_error)
		return ""
	var parsed = JSON.parse_string(payload.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		last_error = "返回体不是预期结构"
		return ""
	var choices: Array = parsed["choices"]
	if choices.is_empty():
		last_error = "choices 为空"
		return ""
	last_error = ""
	return str((choices[0] as Dictionary).get("message", {}).get("content", ""))


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
{"pos": [x,y,z], "speed_mps": 数值, "heading_deg": 数值, "weather": "clear|rain|snow|sand", "note": "为什么这组容易出问题"}
要求覆盖：贴墙低速、贴墙高速、赛道外 5~50m、空中落下、正对墙、倒车撞墙、S 弯切内线。
赛道信息：%s
只输出 JSON 数组。""" % [count, track_hint]
	var text := await chat(sys, usr)
	if text.is_empty():
		return []
	var parsed = JSON.parse_string(_strip_code_fence(text))
	if typeof(parsed) != TYPE_ARRAY:
		last_error = "测试用例不是 JSON 数组"
		print("[OpenRouter] %s" % last_error)
		return []
	print("[OpenRouter] AI 生成了 %d 组测试用例" % (parsed as Array).size())
	return parsed


## 让 AI 对一段失败日志做归因（可选，人工排查的辅助）
func diagnose(failure_log: String) -> String:
	if not available:
		return ""
	var sys := "你是物理引擎调试专家，回答用中文，不超过 150 字，直接给最可能的原因和建议的验证方法。"
	return await chat(sys, "下面是赛车游戏的一次失败记录，请归因：\n%s" % failure_log)


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
