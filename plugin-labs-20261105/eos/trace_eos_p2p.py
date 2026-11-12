"""LLDB probe for EOS calls in the isolated Windows test process."""
import lldb


_entries = {}


def report_return(debugger, call):
    process = debugger.GetSelectedTarget().GetProcess()
    frame = process.GetSelectedThread().GetFrameAtIndex(0)
    register = frame.FindRegister("eax")
    code = register.GetValueAsUnsigned() if register.IsValid() else "unavailable"
    print(f"EOS_NATIVE_P2P {call} result={code}", flush=True)


def on_enter(frame, location, _dictionary):
    thread = frame.GetThread()
    process = thread.GetProcess()
    error = lldb.SBError()
    # Windows x64: a breakpoint at the function entry sees the return address at RSP.
    return_address = process.ReadUnsignedFromMemory(frame.GetSP(), 8, error)
    if error.Success() and return_address:
        bp = process.GetTarget().BreakpointCreateByAddress(return_address)
        bp.SetOneShot(True)
        bp.SetThreadID(thread.GetThreadID())
        call = _entries[location.GetBreakpoint().GetID()]
        # Registering a Python callback inside another callback breaks the LLDB 18 session dictionary.
        commands = lldb.SBStringList()
        commands.AppendString(f"script {__name__}.report_return(lldb.debugger, {call!r})")
        commands.AppendString("continue")
        bp.SetCommandLineCommands(commands)
    return False


def install(debugger):
    target = debugger.GetSelectedTarget()
    for name in ("EOS_P2P_SendPacket", "EOS_P2P_AcceptConnection"):
        bp = target.BreakpointCreateByName(name, "EOSSDK-Win64-Shipping.dll")
        _entries[bp.GetID()] = name
        bp.SetOneShot(True)
        bp.SetScriptCallbackFunction(__name__ + ".on_enter")
