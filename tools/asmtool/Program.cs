// Managed-assembly tooling for moving a Mono game onto IL2CPP/iOS.
//
//   asmtool scan <Managed dir>
//       List native libraries reached through P/Invoke and assemblies that use
//       System.Reflection.Emit (which IL2CPP cannot run).
//
//   asmtool internalize --out <dir> --stub <stub.c> [--overrides <file.c>]...
//                       --module <name> [--module <name>]... <assembly.dll>...
//       Rewrite P/Invokes into the named native libraries to "__Internal" so
//       IL2CPP links them statically, and generate a C stub defining every
//       entry point that is not defined in an overrides file. Generated stubs
//       return 0; overrides hold hand-written bodies for functions where 0
//       means the wrong thing (e.g. "init succeeded").
//
//   asmtool guard --method <Namespace.Type::Method> [--method ...] <assembly.dll>
//       Rewrite void methods in place so an exception they throw is printed and
//       swallowed: for optional systems that cannot work on iOS (they would
//       otherwise abort the game's start-up).
using System.Text;
using System.Text.RegularExpressions;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

return args.Length > 0 && args[0] == "scan" ? Scan(args.Skip(1).ToArray())
     : args.Length > 0 && args[0] == "internalize" ? Internalize(args.Skip(1).ToArray())
     : args.Length > 0 && args[0] == "guard" ? Guard(args.Skip(1).ToArray())
     : Usage();

static int Usage()
{
    Console.Error.WriteLine("usage: asmtool scan <dir> | asmtool internalize --out <dir> --stub <c> [--overrides <c>] --module <lib> <dll>...");
    return 2;
}

static int Scan(string[] args)
{
    if (args.Length != 1) return Usage();
    var pinvokes = new SortedDictionary<string, SortedSet<string>>();
    var emitUsers = new SortedSet<string>();
    foreach (var path in Directory.GetFiles(args[0], "*.dll").OrderBy(p => p))
    {
        var asm = Path.GetFileName(path);
        ModuleDefinition module;
        try { module = ModuleDefinition.ReadModule(path); }
        catch (BadImageFormatException) { continue; }
        using (module)
        {
            foreach (var type in AllTypes(module))
                foreach (var m in type.Methods.Where(m => m.IsPInvokeImpl && m.PInvokeInfo != null))
                {
                    var lib = m.PInvokeInfo.Module.Name;
                    if (!pinvokes.TryGetValue(lib, out var set)) pinvokes[lib] = set = new();
                    set.Add(asm);
                }
            if (module.GetTypeReferences().Any(t => t.Namespace == "System.Reflection.Emit"))
                emitUsers.Add(asm);
        }
    }
    Console.WriteLine("== P/Invoke target libraries");
    foreach (var (lib, set) in pinvokes) Console.WriteLine($"{lib}: {string.Join(", ", set)}");
    Console.WriteLine("== Assemblies referencing System.Reflection.Emit");
    foreach (var a in emitUsers) Console.WriteLine(a);
    return 0;
}

static int Internalize(string[] args)
{
    string outDir = null, stubPath = null;
    var overrides = new List<string>();
    var modules = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var inputs = new List<string>();
    for (int i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--out": outDir = args[++i]; break;
            case "--stub": stubPath = args[++i]; break;
            case "--overrides": overrides.Add(args[++i]); break;
            case "--module": modules.Add(args[++i]); break;
            default: inputs.Add(args[i]); break;
        }
    }
    if (outDir == null || stubPath == null || modules.Count == 0 || inputs.Count == 0) return Usage();
    Directory.CreateDirectory(outDir);

    // Entry points defined by hand: every "name(" in an overrides file. Only names
    // that are also P/Invoke entry points matter, so over-matching is harmless.
    var defined = new HashSet<string>();
    var overrideText = new StringBuilder();
    foreach (var o in overrides)
    {
        var text = File.ReadAllText(o);
        overrideText.AppendLine($"// ---- from {Path.GetFileName(o)}").AppendLine(text);
        foreach (Match match in Regex.Matches(text, @"\b([A-Za-z_]\w*)\s*\("))
            defined.Add(match.Groups[1].Value);
    }

    var entryPoints = new SortedSet<string>(StringComparer.Ordinal);
    foreach (var input in inputs)
    {
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(input)));
        var module = ModuleDefinition.ReadModule(input, new ReaderParameters { AssemblyResolver = resolver });
        int changed = 0;
        ModuleReference internalRef = module.ModuleReferences.FirstOrDefault(r => r.Name == "__Internal");
        foreach (var type in AllTypes(module))
            foreach (var m in type.Methods.Where(m => m.IsPInvokeImpl && m.PInvokeInfo != null))
            {
                if (!modules.Contains(m.PInvokeInfo.Module.Name)) continue;
                if (internalRef == null) { internalRef = new ModuleReference("__Internal"); module.ModuleReferences.Add(internalRef); }
                entryPoints.Add(string.IsNullOrEmpty(m.PInvokeInfo.EntryPoint) ? m.Name : m.PInvokeInfo.EntryPoint);
                m.PInvokeInfo.Module = internalRef;
                changed++;
            }
        var dest = Path.Combine(outDir, Path.GetFileName(input));
        module.Write(dest);
        module.Dispose();
        Console.WriteLine($"{Path.GetFileName(input)}: {changed} P/Invokes -> __Internal");
    }

    var sb = new StringBuilder();
    sb.AppendLine("// Generated by asmtool internalize. Native stand-in for: " + string.Join(", ", modules.OrderBy(m => m)));
    sb.AppendLine("// Every entry point returns 0 unless an overrides file defines it.");
    sb.AppendLine("#include <stdint.h>");
    sb.AppendLine("#include <stddef.h>");
    sb.AppendLine("#include <string.h>");
    sb.Append(overrideText);
    sb.AppendLine("// ---- generated");
    int generated = 0;
    foreach (var ep in entryPoints.Where(e => !defined.Contains(e)))
    {
        sb.AppendLine($"__attribute__((used)) intptr_t {ep}(void) {{ return 0; }}");
        generated++;
    }
    File.WriteAllText(stubPath, sb.ToString());
    Console.WriteLine($"stub: {entryPoints.Count} entry points, {generated} generated, {entryPoints.Count - generated} from overrides -> {stubPath}");
    return 0;
}

static int Guard(string[] args)
{
    var targets = new List<string>();
    string input = null;
    for (int i = 0; i < args.Length; i++)
    {
        if (args[i] == "--method") targets.Add(args[++i]);
        else input = args[i];
    }
    if (input == null || targets.Count == 0) return Usage();

    var resolver = new DefaultAssemblyResolver();
    resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(input)));
    var bytes = File.ReadAllBytes(input);  // read fully so the file can be rewritten in place
    using var module = ModuleDefinition.ReadModule(new MemoryStream(bytes), new ReaderParameters { AssemblyResolver = resolver });
    var core = module.TypeSystem.CoreLibrary;
    var console = new TypeReference("System", "Console", module, core);
    var writeObject = new MethodReference("WriteLine", module.TypeSystem.Void, console) { Parameters = { new ParameterDefinition(module.TypeSystem.Object) } };
    var writeString = new MethodReference("WriteLine", module.TypeSystem.Void, console) { Parameters = { new ParameterDefinition(module.TypeSystem.String) } };
    var exception = new TypeReference("System", "Exception", module, core);

    int failed = 0;
    foreach (var target in targets)
    {
        var parts = target.Split("::");
        var type = AllTypes(module).FirstOrDefault(t => t.FullName == parts[0]);
        var methods = type?.Methods.Where(m => m.Name == parts[1] && m.HasBody).ToList() ?? new();
        if (methods.Count == 0) { Console.Error.WriteLine($"guard: {target} not found"); failed++; continue; }
        foreach (var method in methods)
        {
            if (method.ReturnType.MetadataType != MetadataType.Void) { Console.Error.WriteLine($"guard: {target} does not return void"); failed++; continue; }
            var body = method.Body;
            body.SimplifyMacros();
            var il = body.GetILProcessor();
            var end = il.Create(OpCodes.Ret);
            foreach (var ins in body.Instructions.Where(x => x.OpCode == OpCodes.Ret).ToList())
            {
                ins.OpCode = OpCodes.Leave;
                ins.Operand = end;
            }
            var tryStart = body.Instructions[0];
            var handler = il.Create(OpCodes.Call, writeObject);
            il.Append(handler);
            il.Append(il.Create(OpCodes.Ldstr, $"[recomp] {target} failed and was skipped (not supported on iOS)"));
            il.Append(il.Create(OpCodes.Call, writeString));
            il.Append(il.Create(OpCodes.Leave, end));
            il.Append(end);
            body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch)
            {
                TryStart = tryStart, TryEnd = handler, HandlerStart = handler, HandlerEnd = end, CatchType = exception,
            });
            body.OptimizeMacros();
            Console.WriteLine($"guarded {method.FullName}");
        }
    }
    if (failed > 0) return 1;
    module.Write(input);
    return 0;
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
