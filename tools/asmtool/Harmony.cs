// asmtool harmony: Harmony patches applied at port time, for iOS where code cannot be patched
// at run time.
//
//   asmtool harmony --targets <dir> [--search <dir>]... <mod.dll>...
//
// Finds the [HarmonyPatch] classes of each mod assembly (rewritten in place) and weaves their
// prefixes and postfixes into the target methods of the assemblies in --targets (the port's
// game assemblies, rewritten in place), following Harmony's rules:
//   - a target comes from the class's [HarmonyPatch] attributes (type, method name, argument
//     types, MethodType Normal/Getter/Setter/Constructor/StaticConstructor) or from a static
//     TargetMethod() made of AccessTools.Method/DeclaredMethod/PropertyGetter/... calls;
//   - patch parameters bind by name to the original's arguments (by value or ref), or are
//     __instance, __result, __state, __runOriginal, __originalMethod, __0..__n, ___field;
//   - a prefix returning false skips the original; postfixes run on every return, and one
//     that returns the result type passes it through;
//   - finalizers run last, whether or not prefixes, original or postfixes threw: they get
//     the exception as __exception, and one returning Exception replaces it (null swallows);
//   - priorities order patches as Harmony does (higher first).
// Woven patches run only once the game has loaded the mod (the libil2cpp patch reveals it on
// Assembly.Load) and its Prepare(), if any, returned true: as on the Mac, where they take
// effect when the mod calls PatchAll. Transpilers, reverse patches and anything
// else the weaver cannot express are reported as skipped, one JSON object per line:
//   {"mod", "patch", "kind", "target", "status": "woven"|"skipped", "reason"}
using System.Text.Json;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

static class HarmonyWeaver
{
    const string Lib = "HarmonyLib";

    sealed class PatchInfo
    {
        public TypeReference DeclaringType;
        public string MethodName;
        public int MethodType; // HarmonyLib.MethodType
        public List<TypeReference> ArgumentTypes;
        public int Priority = 400;
    }

    sealed class Patch
    {
        public ModuleDefinition Mod;
        public TypeDefinition Class;
        public MethodDefinition Method;
        public string Kind; // prefix, postfix
        public MethodDefinition Target;
        public int Priority;
        public int Order;
        public MethodDefinition Gate;
    }

    static readonly List<Dictionary<string, object>> Report = new();

    static void Say(Patch p, string kind, string target, string status, string reason = null) =>
        Say(p.Mod.Assembly.Name.Name, p.Class.FullName + "::" + p.Method?.Name, kind, target, status, reason);

    static void Say(string mod, string patch, string kind, string target, string status, string reason = null)
    {
        var line = new Dictionary<string, object> { ["mod"] = mod, ["patch"] = patch, ["kind"] = kind, ["target"] = target, ["status"] = status };
        if (reason != null) line["reason"] = reason;
        Console.WriteLine(JsonSerializer.Serialize(line));
    }

    public static int Run(string[] args)
    {
        string targetsDir = null;
        var search = new List<string>();
        var mods = new List<string>();
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--targets") targetsDir = args[++i];
            else if (args[i] == "--search") search.Add(args[++i]);
            else mods.Add(args[i]);
        }
        if (targetsDir == null || mods.Count == 0)
        {
            Console.Error.WriteLine("usage: asmtool harmony --targets <dir> [--search <dir>]... <mod.dll>...");
            return 2;
        }

        // One in-memory module per assembly, shared by reference resolution and the writer, so
        // what is woven into a target is what gets written back to its file.
        var targetModules = Directory.GetFiles(targetsDir, "*.dll").ToDictionary(p => Path.GetFileNameWithoutExtension(p), p => Path.GetFullPath(p));
        var modPaths = mods.Select(Path.GetFullPath).ToList();
        foreach (var m in modPaths) targetModules.TryAdd(Path.GetFileNameWithoutExtension(m), m);
        var modules = new Dictionary<string, ModuleDefinition>(StringComparer.Ordinal);
        var resolver = new SharedResolver();
        foreach (var d in resolver.GetSearchDirectories()) resolver.RemoveSearchDirectory(d);
        search.ForEach(resolver.AddSearchDirectory);
        ModuleDefinition Open(string path)
        {
            if (!modules.TryGetValue(path, out var m))
                modules[path] = m = ModuleDefinition.ReadModule(new MemoryStream(File.ReadAllBytes(path)),
                    new ReaderParameters { AssemblyResolver = resolver, ReadingMode = ReadingMode.Immediate });
            return m;
        }
        resolver.Hook = name => targetModules.TryGetValue(name, out var path) ? Open(path).Assembly : null;
        FindTypeByName = name => targetModules.Values.Where(p => !modPaths.Contains(p)).Select(p => Open(p).GetType(name)).FirstOrDefault(t => t != null);

        var patches = new List<Patch>();
        int order = 0;
        foreach (var modPath in modPaths)
        {
            var mod = Open(modPath);
            foreach (var cls in AllTypes(mod))
            {
                var classAttrs = cls.CustomAttributes.Where(a => IsHarmony(a, "HarmonyPatch") || IsHarmony(a, "HarmonyPatchAll")).ToList();
                if (classAttrs.Count == 0) continue;
                if (classAttrs.Any(a => IsHarmony(a, "HarmonyPatchAll")))
                {
                    Say(mod.Assembly.Name.Name, cls.FullName, "class", null, "skipped", "[HarmonyPatchAll] (every method of a type) is not supported");
                    continue;
                }
                var info = new PatchInfo();
                foreach (var a in classAttrs) Merge(info, a);
                foreach (var a in cls.CustomAttributes.Where(a => IsHarmony(a, "HarmonyPriority"))) info.Priority = (int)a.ConstructorArguments[0].Value;

                MethodDefinition Find(string attr, string name) =>
                    cls.Methods.FirstOrDefault(m => m.IsStatic && m.CustomAttributes.Any(a => IsHarmony(a, attr)))
                    ?? cls.Methods.FirstOrDefault(m => m.IsStatic && m.Name == name);

                foreach (var (attr, name, kind) in new[] { ("HarmonyTranspiler", "Transpiler", "transpiler") })
                {
                    var m = Find(attr, name);
                    if (m != null) Say(mod.Assembly.Name.Name, cls.FullName + "::" + m.Name, kind, null, "skipped", $"{kind}s are not supported by the port-time weaver");
                }
                foreach (var m in cls.Methods.Where(m => m.CustomAttributes.Any(a => IsHarmony(a, "HarmonyReversePatch"))))
                    Say(mod.Assembly.Name.Name, cls.FullName + "::" + m.Name, "reverse patch", null, "skipped", "reverse patches are not supported by the port-time weaver");

                var found = new List<(MethodDefinition Method, string Kind)>();
                foreach (var (attr, name, kind) in new[] { ("HarmonyPrefix", "Prefix", "prefix"), ("HarmonyPostfix", "Postfix", "postfix"), ("HarmonyFinalizer", "Finalizer", "finalizer") })
                {
                    var m = Find(attr, name);
                    if (m != null) found.Add((m, kind));
                }
                if (found.Count == 0) continue;

                string error = null;
                var targets = new List<MethodDefinition>();
                var targetMethod = cls.Methods.FirstOrDefault(m => m.IsStatic && (m.Name == "TargetMethod" || m.CustomAttributes.Any(a => IsHarmony(a, "HarmonyTargetMethod"))));
                var targetMethods = cls.Methods.FirstOrDefault(m => m.IsStatic && (m.Name == "TargetMethods" || m.CustomAttributes.Any(a => IsHarmony(a, "HarmonyTargetMethods"))));
                if (targetMethods != null) error = "TargetMethods() (several targets chosen at run time) is not supported";
                else if (targetMethod != null)
                {
                    var t = InterpretTargetMethod(targetMethod, out error);
                    if (t != null) targets.Add(t);
                }
                else
                {
                    var t = ResolveTarget(info, out error);
                    if (t != null) targets.Add(t);
                }
                foreach (var (m, kind) in found)
                {
                    var p = new Patch { Mod = mod, Class = cls, Method = m, Kind = kind, Order = order++ };
                    var prio = m.CustomAttributes.FirstOrDefault(a => IsHarmony(a, "HarmonyPriority"));
                    p.Priority = prio != null ? (int)prio.ConstructorArguments[0].Value : info.Priority;
                    if (error != null) { Say(p, kind, null, "skipped", error); continue; }
                    foreach (var t in targets)
                    {
                        if (m.HasGenericParameters) { Say(p, kind, t.FullName, "skipped", "generic patch methods are not supported"); continue; }
                        if (!targetModules.ContainsKey(t.Module.Assembly.Name.Name))
                        {
                            Say(p, kind, t.FullName, "skipped", $"{t.Module.Assembly.Name.Name} is not one of the game's own assemblies (engine and class-library code comes from Unity's iOS player)");
                            continue;
                        }
                        patches.Add(new Patch { Mod = mod, Class = cls, Method = m, Kind = kind, Target = t, Priority = p.Priority, Order = p.Order });
                    }
                }
            }
        }

        // Targets were resolved through the shared resolver; re-open them as writable modules.
        int failed = 0;
        foreach (var group in patches.GroupBy(p => p.Target.FullName + "@" + p.Target.Module.Assembly.Name.Name))
        {
            var first = group.First();
            var target = first.Target;
            if (target == null || !target.HasBody)
            {
                foreach (var p in group) Say(p, p.Kind, first.Target.FullName, "skipped", "the target has no method body (abstract, extern or interface)");
                continue;
            }
            if (target.DeclaringType.HasGenericParameters || target.HasGenericParameters)
            {
                foreach (var p in group) Say(p, p.Kind, target.FullName, "skipped", "generic targets are not supported");
                continue;
            }
            var ordered = group.OrderByDescending(p => p.Priority).ThenBy(p => p.Order).ToList();
            foreach (var p in ordered) p.Gate = GateFor(p.Mod, p.Class, target);
            var errors = new Dictionary<Patch, string>();
            var woven = Weave(target, ordered, errors);
            foreach (var p in ordered)
            {
                if (errors.TryGetValue(p, out var why)) { Say(p, p.Kind, target.FullName, "skipped", why); failed++; }
                else if (woven.Contains(p)) Say(p, p.Kind, target.FullName, "woven");
            }
        }
        var touched = patches.Select(p => p.Target.Module).Concat(Gates.Keys).ToHashSet();
        foreach (var (path, module) in modules.Where(m => touched.Contains(m.Value)))
            module.Write(path);
        return 0;
    }

    static Func<string, TypeDefinition> FindTypeByName;

    sealed class SharedResolver : DefaultAssemblyResolver
    {
        public Func<string, AssemblyDefinition> Hook;

        public override AssemblyDefinition Resolve(AssemblyNameReference name, ReaderParameters parameters)
        {
            var hooked = Hook?.Invoke(name.Name);
            if (hooked != null) return hooked;
            parameters.ReadingMode = ReadingMode.Immediate;
            parameters.InMemory = true;
            return base.Resolve(name, parameters);
        }
    }

    // ---- finding targets ---------------------------------------------------------------

    static bool IsHarmony(CustomAttribute a, string name) => a.AttributeType.Namespace == Lib && a.AttributeType.Name == name;

    static void Merge(PatchInfo info, CustomAttribute a)
    {
        var ps = a.Constructor.Parameters;
        bool typeNameFirst = ps.Count >= 2 && ps[0].ParameterType.FullName == "System.String" && ps[1].ParameterType.FullName == "System.String";
        CustomAttributeArgument[] variations = null;
        for (int i = 0; i < ps.Count; i++)
        {
            var value = a.ConstructorArguments[i].Value;
            switch (ps[i].ParameterType.FullName)
            {
                case "System.Type": info.DeclaringType = (TypeReference)value; break;
                case "System.String" when typeNameFirst && i == 0:
                    info.DeclaringType = new TypeReference("", (string)value, null, null); // by name: looked up in the game
                    break;
                case "System.String": info.MethodName = (string)value; break;
                case "System.Type[]": info.ArgumentTypes = ((CustomAttributeArgument[])value)?.Select(x => (TypeReference)x.Value).ToList(); break;
                case "HarmonyLib.ArgumentType[]": variations = (CustomAttributeArgument[])value; break;
                case "HarmonyLib.MethodType": info.MethodType = (int)value; break;
            }
        }
        if (variations != null && info.ArgumentTypes != null)
            for (int i = 0; i < variations.Length && i < info.ArgumentTypes.Count; i++)
                info.ArgumentTypes[i] = (int)variations[i].Value switch
                {
                    1 or 2 => new ByReferenceType(info.ArgumentTypes[i]), // Ref, Out
                    3 => new PointerType(info.ArgumentTypes[i]),
                    _ => info.ArgumentTypes[i],
                };
    }

    static MethodDefinition ResolveTarget(PatchInfo info, out string error)
    {
        error = null;
        if (info.DeclaringType == null) { error = "no target type: [HarmonyPatch] names no type and there is no TargetMethod()"; return null; }
        var type = info.DeclaringType.Scope == null ? FindTypeByName(info.DeclaringType.Name) : info.DeclaringType.Resolve();
        if (type == null) { error = $"target type {info.DeclaringType.FullName} not found in this game version"; return null; }
        switch (info.MethodType)
        {
            case 0:
                if (info.MethodName == null) { error = $"no method name for {type.FullName}"; return null; }
                return Pick(type.Methods.Where(m => m.Name == info.MethodName && !m.IsConstructor), info.ArgumentTypes, $"{type.FullName}.{info.MethodName}", out error);
            case 1:
            case 2:
                var prop = type.Properties.FirstOrDefault(p => p.Name == info.MethodName);
                var accessor = info.MethodType == 1 ? prop?.GetMethod : prop?.SetMethod;
                if (accessor == null) error = $"property {type.FullName}.{info.MethodName} has no {(info.MethodType == 1 ? "getter" : "setter")}";
                return accessor;
            case 3:
                return Pick(type.Methods.Where(m => m.IsConstructor && !m.IsStatic), info.ArgumentTypes ?? new List<TypeReference>(), $"{type.FullName} constructor", out error);
            case 4:
                var cctor = type.Methods.FirstOrDefault(m => m.IsConstructor && m.IsStatic);
                if (cctor == null) error = $"{type.FullName} has no static constructor";
                return cctor;
            default:
                error = $"MethodType {info.MethodType} (enumerator, async, operators, events) is not supported";
                return null;
        }
    }

    static MethodDefinition Pick(IEnumerable<MethodDefinition> candidates, List<TypeReference> args, string what, out string error)
    {
        error = null;
        var list = candidates.ToList();
        if (args != null)
            list = list.Where(m => m.Parameters.Count == args.Count && m.Parameters.Select((p, i) => SameType(p.ParameterType, args[i])).All(x => x)).ToList();
        if (list.Count == 1) return list[0];
        error = list.Count == 0 ? $"{what} not found in this game version" : $"{what} is overloaded: the patch must give argument types";
        return null;
    }

    static bool SameType(TypeReference a, TypeReference b) => Strip(a.FullName) == Strip(b.FullName);

    static string Strip(string name) => name.Replace("/", "+");

    // A TargetMethod() body made of typeof(), string and Type[] constants and AccessTools lookups.
    static MethodDefinition InterpretTargetMethod(MethodDefinition tm, out string error)
    {
        error = null;
        var stack = new Stack<object>();
        var locals = new Dictionary<int, object>();
        object Pop() => stack.Count > 0 ? stack.Pop() : throw new InvalidOperationException("stack underflow");
        try
        {
            foreach (var ins in tm.Body.Instructions)
            {
                var op = ins.OpCode.Code;
                switch (op)
                {
                    case Code.Nop: break;
                    case Code.Ldtoken: stack.Push(ins.Operand); break;
                    case Code.Ldstr: stack.Push((string)ins.Operand); break;
                    case Code.Ldnull: stack.Push(null); break;
                    case Code.Ldc_I4_0: case Code.Ldc_I4_1: case Code.Ldc_I4_2: case Code.Ldc_I4_3: case Code.Ldc_I4_4:
                    case Code.Ldc_I4_5: case Code.Ldc_I4_6: case Code.Ldc_I4_7: case Code.Ldc_I4_8:
                        stack.Push(op - Code.Ldc_I4_0); break;
                    case Code.Ldc_I4_S: stack.Push((int)(sbyte)ins.Operand); break;
                    case Code.Ldc_I4: stack.Push((int)ins.Operand); break;
                    case Code.Newarr: stack.Push(new object[(int)Pop()]); break;
                    case Code.Dup: stack.Push(stack.Peek()); break;
                    case Code.Stelem_Ref:
                        { var v = Pop(); var i = (int)Pop(); var arr = (object[])Pop(); arr[i] = v; break; }
                    case Code.Stloc_0: case Code.Stloc_1: case Code.Stloc_2: case Code.Stloc_3:
                        locals[op - Code.Stloc_0] = Pop(); break;
                    case Code.Ldloc_0: case Code.Ldloc_1: case Code.Ldloc_2: case Code.Ldloc_3:
                        stack.Push(locals[op - Code.Ldloc_0]); break;
                    case Code.Stloc_S: case Code.Stloc: locals[((VariableDefinition)ins.Operand).Index] = Pop(); break;
                    case Code.Ldloc_S: case Code.Ldloc: stack.Push(locals[((VariableDefinition)ins.Operand).Index]); break;
                    case Code.Br_S: case Code.Br:
                        if (((Instruction)ins.Operand) != ins.Next) throw new NotSupportedException("branches");
                        break;
                    case Code.Castclass: break;
                    case Code.Call: case Code.Callvirt:
                        stack.Push(Call((MethodReference)ins.Operand, stack));
                        break;
                    case Code.Ret:
                        if (Pop() is MethodDefinition result) return result;
                        error = "TargetMethod() returned nothing the weaver could follow";
                        return null;
                    default:
                        throw new NotSupportedException(ins.OpCode.Name);
                }
            }
        }
        catch (Exception e) when (e is NotSupportedException or InvalidOperationException or InvalidCastException or KeyNotFoundException)
        {
            error = $"TargetMethod() does more than the weaver can follow ({e.Message}); give the target in [HarmonyPatch] instead";
            return null;
        }
        error = "TargetMethod() has no return";
        return null;
    }

    static object Call(MethodReference m, Stack<object> stack)
    {
        var args = new object[m.Parameters.Count];
        for (int i = args.Length - 1; i >= 0; i--) args[i] = stack.Pop();
        object self = m.HasThis ? stack.Pop() : null;
        string Name(object o) => (string)o;
        TypeDefinition Type(object o) => o switch { TypeReference t => t.Resolve(), null => null, _ => throw new InvalidCastException("not a type") };
        List<TypeReference> Types(object o) => o == null ? null : ((object[])o).Select(x => (TypeReference)x).ToList();
        string owner = m.DeclaringType.FullName;
        if (owner == "System.Type" && m.Name == "GetTypeFromHandle") return args[0];
        if (owner == "System.Type" && m.Name == "MakeByRefType") return new ByReferenceType((TypeReference)self);
        if (owner == "System.Type" && m.Name == "MakeArrayType" && args.Length == 0) return new ArrayType((TypeReference)self);
        if (owner == "System.Type" && m.Name == "GetMethod")
        {
            var t = Type(self);
            var types = args.Length > 0 && args[^1] is object[] ? Types(args[^1]) : null;
            return Lookup(t, Name(args[0]), types, declaredOnly: false);
        }
        if (owner == "System.Type" && (m.Name == "GetConstructor"))
            return Pick(Type(self).Methods.Where(x => x.IsConstructor && !x.IsStatic), Types(args[^1]), "constructor", out _);
        if (owner == "System.Type" && m.Name == "GetProperty") return Type(self).Properties.First(p => p.Name == Name(args[0]));
        if (owner == "System.Reflection.PropertyInfo" && m.Name == "GetGetMethod") return ((PropertyDefinition)self).GetMethod;
        if (owner == "System.Reflection.PropertyInfo" && m.Name == "GetSetMethod") return ((PropertyDefinition)self).SetMethod;
        if (owner == "System.Reflection.PropertyInfo" && m.Name == "get_GetMethod") return ((PropertyDefinition)self).GetMethod;
        if (owner == "System.Reflection.PropertyInfo" && m.Name == "get_SetMethod") return ((PropertyDefinition)self).SetMethod;
        if (owner == "HarmonyLib.AccessTools")
        {
            if (m.Parameters.Count > 0 && m.Parameters[0].ParameterType.FullName == "System.String" && m.Name != "TypeByName")
                throw new NotSupportedException($"AccessTools.{m.Name}(\"Type:Name\")");
            switch (m.Name)
            {
                case "Method": return Lookup(Type(args[0]), Name(args[1]), Types(args.ElementAtOrDefault(2)), declaredOnly: false);
                case "DeclaredMethod": return Lookup(Type(args[0]), Name(args[1]), Types(args.ElementAtOrDefault(2)), declaredOnly: true);
                case "PropertyGetter": case "DeclaredPropertyGetter": return Property(Type(args[0]), Name(args[1]), m.Name.StartsWith("Declared"))?.GetMethod;
                case "PropertySetter": case "DeclaredPropertySetter": return Property(Type(args[0]), Name(args[1]), m.Name.StartsWith("Declared"))?.SetMethod;
                case "Constructor": case "DeclaredConstructor":
                    return Pick(Type(args[0]).Methods.Where(x => x.IsConstructor && !x.IsStatic), Types(args.ElementAtOrDefault(1)) ?? new List<TypeReference>(), "constructor", out _);
            }
        }
        throw new NotSupportedException($"{owner}.{m.Name}");
    }

    static MethodDefinition Lookup(TypeDefinition type, string name, List<TypeReference> args, bool declaredOnly)
    {
        for (var t = type; t != null; t = declaredOnly ? null : t.BaseType?.Resolve())
        {
            var found = Pick(t.Methods.Where(m => m.Name == name), args, name, out var error);
            if (found != null) return found;
            if (error.Contains("overloaded") && args == null)
                return Pick(t.Methods.Where(m => m.Name == name), new List<TypeReference>(), name, out _);
        }
        return null;
    }

    static PropertyDefinition Property(TypeDefinition type, string name, bool declaredOnly)
    {
        for (var t = type; t != null; t = declaredOnly ? null : t.BaseType?.Resolve())
        {
            var p = t.Properties.FirstOrDefault(x => x.Name == name);
            if (p != null) return p;
        }
        return null;
    }

    // ---- the gate: patches act only for a mod the game loaded, once its Prepare() agreed ------

    static readonly Dictionary<ModuleDefinition, (TypeDefinition Type, MethodDefinition Loaded)> Gates = new();
    static readonly Dictionary<string, MethodDefinition> ClassGates = new();

    static MethodDefinition GateFor(ModuleDefinition mod, TypeDefinition cls, MethodDefinition target)
    {
        var key = cls.FullName + "@" + mod.Assembly.Name.Name;
        if (ClassGates.TryGetValue(key, out var existing)) return existing;
        var ts = mod.TypeSystem;
        if (!Gates.TryGetValue(mod, out var gate))
        {
            var type = new TypeDefinition("Recomp", "HarmonyGate", TypeAttributes.Public | TypeAttributes.Abstract | TypeAttributes.Sealed | TypeAttributes.BeforeFieldInit, ts.Object);
            mod.Types.Add(type);
            // [DllImport("__Internal")] static extern int recomp_mod_assembly_loaded(string name): libil2cpp patch.
            var internalRef = mod.ModuleReferences.FirstOrDefault(r => r.Name == "__Internal");
            if (internalRef == null) { internalRef = new ModuleReference("__Internal"); mod.ModuleReferences.Add(internalRef); }
            var native = new MethodDefinition("recomp_mod_assembly_loaded", MethodAttributes.Private | MethodAttributes.Static | MethodAttributes.PInvokeImpl | MethodAttributes.HideBySig, ts.Int32)
            {
                PInvokeInfo = new PInvokeInfo(PInvokeAttributes.CallConvCdecl | PInvokeAttributes.CharSetAnsi, "recomp_mod_assembly_loaded", internalRef),
                ImplAttributes = MethodImplAttributes.PreserveSig,
            };
            native.Parameters.Add(new ParameterDefinition("name", ParameterAttributes.None, ts.String));
            type.Methods.Add(native);
            var on = new FieldDefinition("s_loaded", FieldAttributes.Private | FieldAttributes.Static, ts.Boolean);
            type.Fields.Add(on);
            // static bool Loaded() { if (!s_loaded) s_loaded = recomp_mod_assembly_loaded("<mod>") != 0; return s_loaded; }
            var loaded = new MethodDefinition("Loaded", MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.HideBySig, ts.Boolean);
            var il = loaded.Body.GetILProcessor();
            var done = il.Create(OpCodes.Ldsfld, on);
            il.Emit(OpCodes.Ldsfld, on);
            il.Emit(OpCodes.Brtrue, done);
            il.Emit(OpCodes.Ldstr, mod.Assembly.Name.Name);
            il.Emit(OpCodes.Call, native);
            il.Emit(OpCodes.Ldc_I4_0);
            il.Emit(OpCodes.Cgt_Un);
            il.Emit(OpCodes.Stsfld, on);
            il.Append(done);
            il.Emit(OpCodes.Ret);
            type.Methods.Add(loaded);
            Gates[mod] = gate = (type, loaded);
        }
        var prepare = cls.Methods.FirstOrDefault(m => m.IsStatic && (m.Name == "Prepare" || m.CustomAttributes.Any(a => IsHarmony(a, "HarmonyPrepare"))));
        if (prepare == null || prepare.ReturnType.MetadataType != MetadataType.Boolean)
        {
            ClassGates[key] = gate.Loaded;
            return gate.Loaded;
        }
        // static bool <Class>() { if (!Loaded()) return false; if (s_n == 0) s_n = Prepare(...) ? 1 : 2; return s_n == 1; }
        int n = ClassGates.Count;
        var state = new FieldDefinition($"s_prepared{n}", FieldAttributes.Private | FieldAttributes.Static, ts.Int32);
        gate.Type.Fields.Add(state);
        var m2 = new MethodDefinition($"Prepared{n}", MethodAttributes.Public | MethodAttributes.Static | MethodAttributes.HideBySig, ts.Boolean);
        var p = m2.Body.GetILProcessor();
        var check = p.Create(OpCodes.Ldsfld, state);
        var no = p.Create(OpCodes.Ldc_I4_0);
        p.Emit(OpCodes.Call, gate.Loaded);
        p.Emit(OpCodes.Brfalse, no);
        p.Emit(OpCodes.Ldsfld, state);
        p.Emit(OpCodes.Brtrue, check);
        foreach (var param in prepare.Parameters)
        {
            if (param.ParameterType.FullName == "System.Reflection.MethodBase") EmitOriginalMethod(p, mod, mod.ImportReference(target));
            else p.Emit(OpCodes.Ldnull);
        }
        p.Emit(OpCodes.Call, prepare);
        var two = p.Create(OpCodes.Ldc_I4_2);
        var store = p.Create(OpCodes.Stsfld, state);
        p.Emit(OpCodes.Brfalse, two);
        p.Emit(OpCodes.Ldc_I4_1);
        p.Emit(OpCodes.Br, store);
        p.Append(two);
        p.Append(store);
        p.Append(check);
        p.Emit(OpCodes.Ldc_I4_1);
        p.Emit(OpCodes.Ceq);
        p.Emit(OpCodes.Ret);
        p.Append(no);
        p.Emit(OpCodes.Ret);
        gate.Type.Methods.Add(m2);
        ClassGates[key] = m2;
        return m2;
    }

    static void EmitOriginalMethod(ILProcessor il, ModuleDefinition module, MethodReference target)
    {
        var core = module.TypeSystem.CoreLibrary;
        var methodBase = new TypeReference("System.Reflection", "MethodBase", module, core);
        var handle = new TypeReference("System", "RuntimeMethodHandle", module, core, true);
        var get = new MethodReference("GetMethodFromHandle", methodBase, methodBase) { Parameters = { new ParameterDefinition(handle) } };
        il.Emit(OpCodes.Ldtoken, target);
        il.Emit(OpCodes.Call, get);
    }

    // ---- weaving -----------------------------------------------------------------------

    static HashSet<Patch> Weave(MethodDefinition target, List<Patch> patches, Dictionary<Patch, string> errors)
    {
        var module = target.Module;
        var body = target.Body;
        var ts = module.TypeSystem;
        var returnType = target.ReturnType;
        bool hasResult = returnType.MetadataType != MetadataType.Void;

        // Check every patch before touching the body: a patch that cannot bind is left out.
        foreach (var p in patches)
        {
            var why = CheckPatch(target, p);
            if (why != null) errors[p] = why;
        }
        var ok = patches.Where(p => !errors.ContainsKey(p)).ToList();
        if (ok.Count == 0) return new HashSet<Patch>();

        body.SimplifyMacros();
        body.InitLocals = true;
        var il = body.GetILProcessor();
        var result = hasResult ? new VariableDefinition(returnType) : null;
        if (result != null) body.Variables.Add(result);
        var runOriginal = new VariableDefinition(ts.Boolean);
        body.Variables.Add(runOriginal);
        var exceptionType = new TypeReference("System", "Exception", module, ts.CoreLibrary);
        bool finalizers = ok.Any(p => p.Kind == "finalizer");
        var exception = finalizers ? new VariableDefinition(exceptionType) : null;
        if (exception != null) body.Variables.Add(exception);
        var states = new Dictionary<TypeDefinition, VariableDefinition>();
        foreach (var p in ok)
        {
            var st = p.Method.Parameters.FirstOrDefault(x => x.Name == "__state");
            if (st != null && !states.ContainsKey(p.Class))
            {
                var v = new VariableDefinition(module.ImportReference(Element(st.ParameterType)));
                body.Variables.Add(v);
                states[p.Class] = v;
            }
        }

        // Every return goes through the postfixes: "ret" becomes "store result; br post".
        var post = il.Create(OpCodes.Nop);
        foreach (var ret in body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList())
        {
            if (hasResult)
            {
                ret.OpCode = OpCodes.Stloc;
                ret.Operand = result;
                il.InsertAfter(ret, il.Create(OpCodes.Br, post));
            }
            else
            {
                ret.OpCode = OpCodes.Br;
                ret.Operand = post;
            }
        }

        // Prefixes, then the original unless one of them returned false.
        var originalStart = body.Instructions[0];
        var head = new List<Instruction>();
        head.Add(il.Create(OpCodes.Ldc_I4_1));
        head.Add(il.Create(OpCodes.Stloc, runOriginal));
        foreach (var p in ok.Where(p => p.Kind == "prefix"))
        {
            var skip = il.Create(OpCodes.Nop);
            head.Add(il.Create(OpCodes.Call, module.ImportReference(p.Gate)));
            head.Add(il.Create(OpCodes.Brfalse, skip));
            head.AddRange(LoadArguments(il, target, p, result, runOriginal, exception, states));
            head.Add(il.Create(OpCodes.Call, module.ImportReference(p.Method)));
            if (p.Method.ReturnType.MetadataType == MetadataType.Boolean)
            {
                head.Add(il.Create(OpCodes.Brtrue, skip));
                head.Add(il.Create(OpCodes.Ldc_I4_0));
                head.Add(il.Create(OpCodes.Stloc, runOriginal));
            }
            head.Add(skip);
        }
        head.Add(il.Create(OpCodes.Ldloc, runOriginal));
        head.Add(il.Create(OpCodes.Brfalse, post));
        foreach (var ins in head) il.InsertBefore(originalStart, ins);

        // Postfixes, then the single return.
        il.Append(post);
        foreach (var p in ok.Where(p => p.Kind == "postfix"))
        {
            var skip = il.Create(OpCodes.Nop);
            il.Append(il.Create(OpCodes.Call, module.ImportReference(p.Gate)));
            il.Append(il.Create(OpCodes.Brfalse, skip));
            foreach (var ins in LoadArguments(il, target, p, result, runOriginal, exception, states)) il.Append(ins);
            il.Append(il.Create(OpCodes.Call, module.ImportReference(p.Method)));
            if (p.Method.ReturnType.MetadataType != MetadataType.Void) il.Append(il.Create(OpCodes.Stloc, result)); // pass-through postfix
            il.Append(skip);
        }
        if (finalizers)
        {
            // try { prefixes; original; postfixes } catch (Exception e) { exception = e; }
            // finalizers; if (exception != null) throw exception;
            var after = il.Create(OpCodes.Nop);
            il.Append(il.Create(OpCodes.Leave, after));
            var handler = il.Create(OpCodes.Stloc, exception);
            il.Append(handler);
            il.Append(il.Create(OpCodes.Leave, after));
            il.Append(after);
            body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch)
            {
                TryStart = head[0], TryEnd = handler, HandlerStart = handler, HandlerEnd = after, CatchType = exceptionType,
            });
            foreach (var p in ok.Where(p => p.Kind == "finalizer"))
            {
                var skip = il.Create(OpCodes.Nop);
                il.Append(il.Create(OpCodes.Call, module.ImportReference(p.Gate)));
                il.Append(il.Create(OpCodes.Brfalse, skip));
                foreach (var ins in LoadArguments(il, target, p, result, runOriginal, exception, states)) il.Append(ins);
                il.Append(il.Create(OpCodes.Call, module.ImportReference(p.Method)));
                if (p.Method.ReturnType.MetadataType != MetadataType.Void) il.Append(il.Create(OpCodes.Stloc, exception));
                il.Append(skip);
            }
            var done = il.Create(OpCodes.Nop);
            il.Append(il.Create(OpCodes.Ldloc, exception));
            il.Append(il.Create(OpCodes.Brfalse, done));
            il.Append(il.Create(OpCodes.Ldloc, exception));
            il.Append(il.Create(OpCodes.Throw));
            il.Append(done);
        }
        if (hasResult) il.Append(il.Create(OpCodes.Ldloc, result));
        il.Append(il.Create(OpCodes.Ret));
        body.OptimizeMacros();
        return ok.ToHashSet();
    }

    static TypeReference Element(TypeReference t) => t is ByReferenceType r ? r.ElementType : t;

    static string CheckPatch(MethodDefinition target, Patch p)
    {
        var m = p.Method;
        if (!m.IsStatic) return "patch methods must be static";
        bool hasResult = target.ReturnType.MetadataType != MetadataType.Void;
        if (p.Kind == "prefix" && m.ReturnType.MetadataType is not (MetadataType.Void or MetadataType.Boolean))
            return $"a prefix returns void or bool, not {m.ReturnType.Name}";
        if (p.Kind == "finalizer" && m.ReturnType.MetadataType != MetadataType.Void && m.ReturnType.FullName != "System.Exception")
            return $"a finalizer returns void or Exception, not {m.ReturnType.Name}";
        if (p.Kind == "postfix" && m.ReturnType.MetadataType != MetadataType.Void)
        {
            if (!hasResult || !SameType(m.ReturnType, target.ReturnType) || m.Parameters.Count == 0 || !SameType(m.Parameters[0].ParameterType, target.ReturnType))
                return "a postfix that returns a value must take and return the original's result type (pass-through)";
        }
        foreach (var param in m.Parameters)
        {
            var why = Bind(target, p, param, out _);
            if (why != null) return why;
        }
        return null;
    }

    enum Source { Instance, Result, State, RunOriginal, OriginalMethod, Argument, Field, Exception, Null }

    static string BoundName(MethodDefinition patch, ParameterDefinition param, out int index)
    {
        index = -1;
        foreach (var a in param.CustomAttributes.Concat(patch.CustomAttributes).Concat(patch.DeclaringType.CustomAttributes).Where(a => IsHarmony(a, "HarmonyArgument")))
        {
            var args = a.ConstructorArguments;
            bool onParam = param.CustomAttributes.Contains(a);
            string newName = args.Count > 1 ? args[1].Value as string : null;
            if (!onParam && newName != param.Name) continue;
            if (args[0].Value is string original) return original;
            if (args[0].Value is int i) { index = i; return null; }
        }
        return param.Name;
    }

    static string Bind(MethodDefinition target, Patch p, ParameterDefinition param, out (Source Kind, object Data) binding)
    {
        binding = (Source.Null, null);
        var type = param.ParameterType;
        bool byRef = type.IsByReference;
        string name = BoundName(p.Method, param, out int index);
        switch (name)
        {
            case "__instance":
                binding = target.IsStatic ? (Source.Null, null) : (Source.Instance, null);
                return null;
            case "__result":
                if (target.ReturnType.MetadataType == MetadataType.Void) return "__result on a method that returns nothing";
                if (!SameType(Element(type), target.ReturnType) && !(Element(type).FullName == "System.Object" && !byRef))
                    return $"__result is {Element(type).FullName}, the original returns {target.ReturnType.FullName}";
                binding = (Source.Result, null);
                return null;
            case "__state":
                if (p.Kind == "prefix" && !byRef) return "a prefix takes __state by ref or out";
                binding = (Source.State, null);
                return null;
            case "__runOriginal":
                if (byRef || type.MetadataType != MetadataType.Boolean) return "__runOriginal is a bool taken by value";
                binding = (Source.RunOriginal, null);
                return null;
            case "__originalMethod":
                binding = (Source.OriginalMethod, null);
                return null;
            case "__exception":
                if (byRef || !IsExceptionType(type)) return "__exception is an Exception taken by value";
                binding = p.Kind == "finalizer" ? (Source.Exception, null) : (Source.Null, null); // none reaches a prefix or postfix
                return null;
            case "__args":
                return "__args is not supported by the port-time weaver";
        }
        if (name != null && name.StartsWith("___"))
        {
            var fieldName = name.Substring(3);
            var field = AllFields(target.DeclaringType).FirstOrDefault(f => f.Name == fieldName);
            if (field == null) return $"field {fieldName} not found on {target.DeclaringType.FullName}";
            if (!field.IsStatic && target.IsStatic) return $"instance field {fieldName} from a static method";
            binding = (Source.Field, field);
            return null;
        }
        if (name != null && name.Length > 2 && name.StartsWith("__") && int.TryParse(name.Substring(2), out var n)) index = n;
        ParameterDefinition arg = index >= 0 ? target.Parameters.ElementAtOrDefault(index) : target.Parameters.FirstOrDefault(x => x.Name == name);
        if (arg == null) return $"parameter {param.Name} matches nothing on {target.FullName}";
        if (!SameType(Element(type), Element(arg.ParameterType)) && !(Element(type).FullName == "System.Object" && !byRef))
            return $"parameter {param.Name} is {Element(type).FullName}, the original's is {Element(arg.ParameterType).FullName}";
        binding = (Source.Argument, arg);
        return null;
    }

    static bool IsExceptionType(TypeReference type)
    {
        for (var t = type.Resolve(); t != null; t = t.BaseType?.Resolve())
            if (t.FullName == "System.Exception") return true;
        return type.FullName == "System.Object";
    }

    static IEnumerable<FieldDefinition> AllFields(TypeDefinition type)
    {
        for (var t = type; t != null; t = t.BaseType?.Resolve())
            foreach (var f in t.Fields) yield return f;
    }

    static List<Instruction> LoadArguments(ILProcessor il, MethodDefinition target, Patch p, VariableDefinition result,
                                           VariableDefinition runOriginal, VariableDefinition exception,
                                           Dictionary<TypeDefinition, VariableDefinition> states)
    {
        var module = target.Module;
        var list = new List<Instruction>();
        foreach (var param in p.Method.Parameters)
        {
            Bind(target, p, param, out var b);
            var type = param.ParameterType;
            bool byRef = type.IsByReference;
            bool boxTo = !byRef && Element(type).FullName == "System.Object";
            switch (b.Kind)
            {
                case Source.Null:
                    list.Add(il.Create(OpCodes.Ldnull));
                    break;
                case Source.Instance:
                    list.Add(il.Create(OpCodes.Ldarg_0));
                    if (target.DeclaringType.IsValueType && !byRef)
                    {
                        list.Add(il.Create(OpCodes.Ldobj, target.DeclaringType));
                        if (boxTo) list.Add(il.Create(OpCodes.Box, target.DeclaringType));
                    }
                    break;
                case Source.Result:
                    list.Add(il.Create(byRef ? OpCodes.Ldloca : OpCodes.Ldloc, result));
                    if (boxTo && result.VariableType.IsValueType) list.Add(il.Create(OpCodes.Box, result.VariableType));
                    break;
                case Source.State:
                    list.Add(il.Create(byRef ? OpCodes.Ldloca : OpCodes.Ldloc, states[p.Class]));
                    break;
                case Source.RunOriginal:
                    list.Add(il.Create(OpCodes.Ldloc, runOriginal));
                    break;
                case Source.Exception:
                    list.Add(il.Create(OpCodes.Ldloc, exception));
                    if (Element(type).FullName != "System.Exception" && Element(type).FullName != "System.Object")
                        list.Add(il.Create(OpCodes.Isinst, module.ImportReference(Element(type))));
                    break;
                case Source.OriginalMethod:
                    var tmp = new List<Instruction>();
                    var proc = new CollectingIL(il, tmp);
                    EmitOriginalMethod(proc.IL, module, target);
                    list.AddRange(proc.Done());
                    break;
                case Source.Field:
                    var f = module.ImportReference((FieldDefinition)b.Data);
                    var fd = (FieldDefinition)b.Data;
                    if (fd.IsStatic) list.Add(il.Create(byRef ? OpCodes.Ldsflda : OpCodes.Ldsfld, f));
                    else
                    {
                        list.Add(il.Create(OpCodes.Ldarg_0));
                        list.Add(il.Create(byRef ? OpCodes.Ldflda : OpCodes.Ldfld, f));
                    }
                    if (boxTo && fd.FieldType.IsValueType) list.Add(il.Create(OpCodes.Box, module.ImportReference(fd.FieldType)));
                    break;
                case Source.Argument:
                    var arg = (ParameterDefinition)b.Data;
                    bool argByRef = arg.ParameterType.IsByReference;
                    if (byRef && !argByRef) list.Add(il.Create(OpCodes.Ldarga, arg));
                    else
                    {
                        list.Add(il.Create(OpCodes.Ldarg, arg));
                        if (!byRef && argByRef) list.Add(il.Create(OpCodes.Ldobj, Element(arg.ParameterType)));
                    }
                    if (boxTo && Element(arg.ParameterType).IsValueType) list.Add(il.Create(OpCodes.Box, Element(arg.ParameterType)));
                    break;
            }
        }
        return list;
    }

    // Runs an emitter that appends to a method body and collects its instructions instead.
    sealed class CollectingIL
    {
        readonly List<Instruction> _into;
        readonly MethodBody _scratch;
        public readonly ILProcessor IL;

        public CollectingIL(ILProcessor il, List<Instruction> into)
        {
            _into = into;
            _scratch = new MethodBody(il.Body.Method);
            IL = _scratch.GetILProcessor();
        }

        public List<Instruction> Done()
        {
            _into.AddRange(_scratch.Instructions);
            _scratch.Instructions.Clear();
            return _into;
        }
    }

    static IEnumerable<TypeDefinition> AllTypes(ModuleDefinition module)
    {
        var stack = new Stack<TypeDefinition>(module.Types);
        while (stack.Count > 0)
        {
            var t = stack.Pop();
            yield return t;
            foreach (var n in t.NestedTypes) stack.Push(n);
        }
    }
}
