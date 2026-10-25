"""Write a minimal iOS app Xcode project.

xcodebuild is only needed for what it does best: automatic provisioning and
signing. The project compiles a few small sources; everything else goes into
the bundle through a run-script phase, which runs before Xcode signs it.
"""
import hashlib
import os


def _id(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def _q(s):
    s = str(s)
    if s and all(c.isalnum() or c in "._/$" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def _dict(d, indent):
    pad = "\t" * indent
    out = ["{"]
    for k, v in d.items():
        out.append(f"{pad}\t{_q(k)} = {_val(v, indent + 1)};")
    out.append(pad + "}")
    return "\n".join(out)


def _val(v, indent):
    if isinstance(v, dict):
        return _dict(v, indent)
    if isinstance(v, (list, tuple)):
        return "(" + "".join(f"{_q(x)}, " for x in v) + ")"
    return _q(v)


def write(path, name, sources, settings, script=None, frameworks=(), resources=()):
    """Create <path>/<name>.xcodeproj with one app target named <name>.

    sources: file paths relative to <path>; settings: target build settings;
    script: shell text run after compiling, before signing; frameworks: SDK
    frameworks to link (names without .framework); resources: files or folders
    (an .xcassets catalog) copied into the bundle.
    """
    proj_dir = os.path.join(path, name + ".xcodeproj")
    os.makedirs(proj_dir, exist_ok=True)
    objs = {}
    root, main_group, target = _id(name, "project"), _id(name, "group"), _id(name, "target")
    product = _id(name, "product")
    objs[product] = {"isa": "PBXFileReference", "explicitFileType": "wrapper.application",
                     "includeInIndex": 0, "path": name + ".app", "sourceTree": "BUILT_PRODUCTS_DIR"}
    children, src_files, fw_files = [], [], []
    for s in sources:
        ref, bf = _id(name, "ref", s), _id(name, "build", s)
        kind = {".m": "sourcecode.c.objc", ".mm": "sourcecode.cpp.objcpp", ".c": "sourcecode.c.c",
                ".swift": "sourcecode.swift"}.get(os.path.splitext(s)[1], "text")
        objs[ref] = {"isa": "PBXFileReference", "lastKnownFileType": kind, "path": s, "sourceTree": "<group>"}
        objs[bf] = {"isa": "PBXBuildFile", "fileRef": ref}
        children.append(ref)
        src_files.append(bf)
    res_files = []
    for r in resources:
        ref, bf = _id(name, "resref", r), _id(name, "resbuild", r)
        kind = "folder.assetcatalog" if r.endswith(".xcassets") else "file"
        objs[ref] = {"isa": "PBXFileReference", "lastKnownFileType": kind, "path": r, "sourceTree": "<group>"}
        objs[bf] = {"isa": "PBXBuildFile", "fileRef": ref}
        children.append(ref)
        res_files.append(bf)
    for fw in frameworks:
        ref, bf = _id(name, "fwref", fw), _id(name, "fwbuild", fw)
        objs[ref] = {"isa": "PBXFileReference", "lastKnownFileType": "wrapper.framework",
                     "name": fw + ".framework", "path": f"System/Library/Frameworks/{fw}.framework",
                     "sourceTree": "SDKROOT"}
        objs[bf] = {"isa": "PBXBuildFile", "fileRef": ref}
        children.append(ref)
        fw_files.append(bf)
    products_group = _id(name, "products")
    objs[products_group] = {"isa": "PBXGroup", "children": [product], "name": "Products", "sourceTree": "<group>"}
    objs[main_group] = {"isa": "PBXGroup", "children": children + [products_group], "sourceTree": "<group>"}
    phases = []
    sp, fp = _id(name, "sources"), _id(name, "frameworks")
    objs[sp] = {"isa": "PBXSourcesBuildPhase", "buildActionMask": 2147483647, "files": src_files,
                "runOnlyForDeploymentPostprocessing": 0}
    objs[fp] = {"isa": "PBXFrameworksBuildPhase", "buildActionMask": 2147483647, "files": fw_files,
                "runOnlyForDeploymentPostprocessing": 0}
    phases += [sp, fp]
    if res_files:
        rp = _id(name, "resources")
        objs[rp] = {"isa": "PBXResourcesBuildPhase", "buildActionMask": 2147483647, "files": res_files,
                    "runOnlyForDeploymentPostprocessing": 0}
        phases.append(rp)
    if script:
        sh = _id(name, "script")
        objs[sh] = {"isa": "PBXShellScriptBuildPhase", "buildActionMask": 2147483647, "files": [],
                    "inputPaths": [], "outputPaths": [], "name": "Bundle game",
                    "runOnlyForDeploymentPostprocessing": 0, "shellPath": "/bin/sh",
                    "shellScript": script, "alwaysOutOfDate": 1}
        phases.append(sh)
    base = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "16.0", "TARGETED_DEVICE_FAMILY": "1,2",
            "CLANG_ENABLE_OBJC_ARC": "YES", "ONLY_ACTIVE_ARCH": "NO", "ARCHS": "arm64"}
    pcfg, tcfg = _id(name, "pcfg"), _id(name, "tcfg")
    objs[pcfg] = {"isa": "XCBuildConfiguration", "buildSettings": base, "name": "Release"}
    objs[tcfg] = {"isa": "XCBuildConfiguration", "buildSettings": dict(
        {"PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic"}, **settings), "name": "Release"}
    plist, tlist = _id(name, "plist"), _id(name, "tlist")
    objs[plist] = {"isa": "XCConfigurationList", "buildConfigurations": [pcfg],
                   "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"}
    objs[tlist] = {"isa": "XCConfigurationList", "buildConfigurations": [tcfg],
                   "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"}
    objs[target] = {"isa": "PBXNativeTarget", "buildConfigurationList": tlist, "buildPhases": phases,
                    "buildRules": [], "dependencies": [], "name": name, "productName": name,
                    "productReference": product, "productType": "com.apple.product-type.application"}
    objs[root] = {"isa": "PBXProject", "attributes": {"LastUpgradeCheck": 1500},
                  "buildConfigurationList": plist, "compatibilityVersion": "Xcode 14.0",
                  "developmentRegion": "en", "hasScannedForEncodings": 0, "knownRegions": ["en", "Base"],
                  "mainGroup": main_group, "productRefGroup": products_group, "projectDirPath": "",
                  "projectRoot": "", "targets": [target]}
    body = "\n".join(f"\t\t{k} = {_dict(v, 2)};" for k, v in objs.items())
    text = ("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n"
            f"\tobjects = {{\n{body}\n\t}};\n\trootObject = {root};\n}}\n")
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
        f.write(text)
    return proj_dir
