import os
import sys

from SCons.Script import BoolVariable


def _append_godot_cpp_tools_path():
    tools_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "godot-cpp", "tools"))
    if tools_dir not in sys.path:
        sys.path.append(tools_dir)


def options(opts, env=None):
    opts.Add(BoolVariable("use_mingw", "Use the MinGW compiler instead of MSVC - only effective on Windows", False))
    opts.Add(BoolVariable("use_static_cpp", "Link MSVC C++ runtime libraries statically", True))
    opts.Add(BoolVariable("silence_msvc", "Accepted for godot-cpp compatibility; not used by this local tool.", False))
    opts.Add(BoolVariable("debug_crt", "Compile with MSVC's debug CRT (/MDd)", False))
    opts.Add(BoolVariable("use_llvm", "Use clang-cl instead of cl", False))
    opts.Add("mingw_prefix", "MinGW prefix; ignored by this local MSVC tool", "")


def exists(env):
    return True


def generate(env):
    _append_godot_cpp_tools_path()
    import common_compiler_flags

    for key in ["PATH", "INCLUDE", "LIB", "LIBPATH", "SystemRoot", "TEMP", "TMP"]:
        value = os.environ.get(key)
        if value:
            env["ENV"][key] = value

    target_arch = {
        "x86_64": "amd64",
        "arm64": "arm64",
        "arm32": "arm",
        "x86_32": "x86",
    }.get(env["arch"], "amd64")

    env["TARGET_ARCH"] = target_arch
    env["MSVC_SETUP_RUN"] = False
    env["MSVS_VERSION"] = "14.3"
    env["MSVC_VERSION"] = "14.3"
    env["is_msvc"] = True
    env["use_mingw"] = False

    env.Tool("msvc")
    env.Tool("mslib")
    env.Tool("mslink")

    if env["use_llvm"]:
        env["CC"] = "clang-cl"
        env["CXX"] = "clang-cl"
    else:
        env["CC"] = "cl"
        env["CXX"] = "cl"
    env["LINK"] = "link"
    env["AR"] = "lib"
    env["SHLIBPREFIX"] = ""
    env["SHLIBSUFFIX"] = ".dll"
    env["IMPLIBPREFIX"] = ""

    env.Append(CPPDEFINES=["TYPED_METHOD_BIND", "NOMINMAX", "WINDOWS_ENABLED"])
    env.Append(CCFLAGS=["/utf-8"])
    env.Append(LINKFLAGS=["/WX"])

    if env["debug_crt"]:
        env.AppendUnique(CCFLAGS=["/MDd"])
    elif env["use_static_cpp"]:
        env.AppendUnique(CCFLAGS=["/MT"])
    else:
        env.AppendUnique(CCFLAGS=["/MD"])

    if env["lto"] == "auto":
        env["lto"] = "none"

    common_compiler_flags.generate(env)
