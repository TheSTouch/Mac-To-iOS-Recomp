// asmtool responders --type <Namespace.Type> [--type ...] [--search <dir>] <assembly.dll>
//
// Steamworks.NET's matchmaking responders (ISteamMatchmakingServerListResponse, ...PingResponse,
// ...PlayersResponse, ...RulesResponse) act as C++ objects for Steam: the constructor marshals a
// VTable of delegates to native memory and pins a box holding its address (m_pGCHandle), and
// (IntPtr)responder, the pinned box's address, is the object whose first word is the vtable.
// The delegates point to instance methods (InternalOn...), which IL2CPP refuses to marshal, so
// the constructor throws and the handle stays empty; casting such a responder dereferences a
// null handle and kills the process.
//
// This rewrites each type so the vtable holds static trampolines instead, marked
// [MonoPInvokeCallback] (IL2CPP matches the attribute by name), with the instance methods'
// signatures. The constructor registers the pinned address -> a weak reference to the instance
// in a synchronized Hashtable; a trampoline looks its thisptr up there and calls the instance's
// InternalOn... method, or does nothing once the responder is gone. The finalizer removes the
// entry before the handle is freed, so an address is never reused while registered.
using System.Collections;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

static class ResponderWeaver
{
    public static int Run(string[] args)
    {
        var targets = new List<string>();
        var search = new List<string>();
        string input = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--type") targets.Add(args[++i]);
            else if (args[i] == "--search") search.Add(args[++i]);
            else input = args[i];
        }
        if (input == null || targets.Count == 0)
        {
            Console.Error.WriteLine("usage: asmtool responders --type <Namespace.Type> [--type ...] [--search <dir>] <dll>");
            return 2;
        }

        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(input)));
        search.ForEach(resolver.AddSearchDirectory);
        var bytes = File.ReadAllBytes(input);  // read fully so the file can be rewritten in place
        using var module = ModuleDefinition.ReadModule(new MemoryStream(bytes), new ReaderParameters { AssemblyResolver = resolver });

        var types = new List<TypeDefinition>();
        foreach (var target in targets)
        {
            var type = module.GetTypes().FirstOrDefault(t => t.FullName == target);
            if (type == null) { Console.Error.WriteLine($"responders: {target} not found"); return 1; }
            types.Add(type);
        }
        var refs = new Refs(module);
        foreach (var type in types)
        {
            var error = Rewrite(type, refs);
            if (error != null) { Console.Error.WriteLine($"responders: {type.FullName}: {error}"); return 1; }
        }
        module.Write(input);
        return 0;
    }

    // The framework types and members the rewrite uses, referenced from the game's own corlib.
    class Refs
    {
        public readonly ModuleDefinition Module;
        public readonly TypeReference Hashtable, WeakReference, IntPtr, SystemType;
        public readonly MethodReference HashtableCtor, Synchronized, GetItem, SetItem, Remove, WeakCtor, GetTarget;
        public MethodReference AttributeCtor;

        public Refs(ModuleDefinition module)
        {
            Module = module;
            var core = module.TypeSystem.CoreLibrary;
            TypeReference T(string ns, string name) => new TypeReference(ns, name, module, core);
            Hashtable = T("System.Collections", "Hashtable");
            WeakReference = T("System", "WeakReference");
            SystemType = T("System", "Type");
            IntPtr = module.TypeSystem.IntPtr;
            var obj = module.TypeSystem.Object;
            var v = module.TypeSystem.Void;
            HashtableCtor = new MethodReference(".ctor", v, Hashtable) { HasThis = true };
            Synchronized = new MethodReference("Synchronized", Hashtable, Hashtable) { Parameters = { new ParameterDefinition(Hashtable) } };
            GetItem = new MethodReference("get_Item", obj, Hashtable) { HasThis = true, Parameters = { new ParameterDefinition(obj) } };
            SetItem = new MethodReference("set_Item", v, Hashtable) { HasThis = true, Parameters = { new ParameterDefinition(obj), new ParameterDefinition(obj) } };
            Remove = new MethodReference("Remove", v, Hashtable) { HasThis = true, Parameters = { new ParameterDefinition(obj) } };
            WeakCtor = new MethodReference(".ctor", v, WeakReference) { HasThis = true, Parameters = { new ParameterDefinition(obj) } };
            GetTarget = new MethodReference("get_Target", obj, WeakReference) { HasThis = true };
        }

        // An internal MonoPInvokeCallbackAttribute(Type) in the assembly, made once.
        public MethodReference Attribute()
        {
            if (AttributeCtor != null) return AttributeCtor;
            var existing = Module.GetTypes().FirstOrDefault(t => t.Name == "MonoPInvokeCallbackAttribute");
            if (existing != null) return AttributeCtor = existing.Methods.First(m => m.IsConstructor && !m.IsStatic);
            var core = Module.TypeSystem.CoreLibrary;
            var attribute = new TypeDefinition("Recomp", "MonoPInvokeCallbackAttribute",
                TypeAttributes.NotPublic | TypeAttributes.Sealed | TypeAttributes.BeforeFieldInit,
                new TypeReference("System", "Attribute", Module, core));
            var ctor = new MethodDefinition(".ctor",
                MethodAttributes.Public | MethodAttributes.HideBySig | MethodAttributes.SpecialName | MethodAttributes.RTSpecialName,
                Module.TypeSystem.Void);
            ctor.Parameters.Add(new ParameterDefinition("type", ParameterAttributes.None, SystemType));
            var il = ctor.Body.GetILProcessor();
            il.Emit(OpCodes.Ldarg_0);
            il.Emit(OpCodes.Call, new MethodReference(".ctor", Module.TypeSystem.Void, attribute.BaseType) { HasThis = true });
            il.Emit(OpCodes.Ret);
            attribute.Methods.Add(ctor);
            Module.Types.Add(attribute);
            return AttributeCtor = ctor;
        }
    }

    static string Rewrite(TypeDefinition type, Refs refs)
    {
        var handle = type.Fields.FirstOrDefault(f => f.Name == "m_pGCHandle");
        if (handle == null) return "no m_pGCHandle field";
        var ctors = type.Methods.Where(m => m.IsConstructor && !m.IsStatic && m.HasBody).ToList();
        var finalizer = type.Methods.FirstOrDefault(m => m.Name == "Finalize" && m.HasBody);
        if (ctors.Count == 0 || finalizer == null) return "no constructor or finalizer";
        // GCHandle's members, as the type already references them.
        var addr = type.Methods.SelectMany(m => m.HasBody ? m.Body.Instructions : Enumerable.Empty<Instruction>())
            .Select(i => i.Operand as MethodReference).FirstOrDefault(m => m?.Name == "AddrOfPinnedObject");
        var isAllocated = finalizer.Body.Instructions.Select(i => i.Operand as MethodReference).FirstOrDefault(m => m?.Name == "get_IsAllocated");
        if (addr == null || isAllocated == null) return "no GCHandle.AddrOfPinnedObject or IsAllocated to reuse";

        var map = new FieldDefinition("recomp_instances", FieldAttributes.Private | FieldAttributes.Static | FieldAttributes.InitOnly, refs.Hashtable);
        type.Fields.Add(map);
        var cctor = type.Methods.FirstOrDefault(m => m.IsConstructor && m.IsStatic);
        if (cctor == null)
        {
            cctor = new MethodDefinition(".cctor",
                MethodAttributes.Private | MethodAttributes.Static | MethodAttributes.HideBySig | MethodAttributes.SpecialName | MethodAttributes.RTSpecialName,
                refs.Module.TypeSystem.Void);
            cctor.Body.GetILProcessor().Emit(OpCodes.Ret);
            type.Methods.Add(cctor);
            type.Attributes &= ~TypeAttributes.BeforeFieldInit;
        }
        var first = cctor.Body.Instructions[0];
        var cil = cctor.Body.GetILProcessor();
        cil.InsertBefore(first, cil.Create(OpCodes.Newobj, refs.HashtableCtor));
        cil.InsertBefore(first, cil.Create(OpCodes.Call, refs.Synchronized));
        cil.InsertBefore(first, cil.Create(OpCodes.Stsfld, map));

        var trampolines = new Dictionary<MethodDefinition, MethodDefinition>();
        foreach (var ctor in ctors)
        {
            var il = ctor.Body.GetILProcessor();
            bool pinned = false;
            foreach (var ins in ctor.Body.Instructions.ToList())
            {
                if (ins.OpCode == OpCodes.Ldftn && ins.Operand is MethodDefinition target && target.DeclaringType == type && !target.IsStatic)
                {
                    if (ins.Previous?.OpCode != OpCodes.Ldarg_0 || ins.Next?.OpCode != OpCodes.Newobj)
                        return $"unexpected code around ldftn {target.Name}";
                    var delegateType = ((MethodReference)ins.Next.Operand).DeclaringType;
                    if (!trampolines.TryGetValue(target, out var trampoline))
                        trampolines[target] = trampoline = Trampoline(type, target, delegateType, map, refs);
                    ins.Previous.OpCode = OpCodes.Ldnull;
                    ins.Operand = trampoline;
                }
                else if (ins.OpCode == OpCodes.Stfld && ins.Operand is FieldReference f && f.Name == handle.Name)
                {
                    // recomp_instances[m_pGCHandle.AddrOfPinnedObject()] = new WeakReference(this);
                    var after = ins;
                    foreach (var add in new[]
                    {
                        il.Create(OpCodes.Ldsfld, map),
                        il.Create(OpCodes.Ldarg_0),
                        il.Create(OpCodes.Ldflda, handle),
                        il.Create(OpCodes.Call, addr),
                        il.Create(OpCodes.Box, refs.IntPtr),
                        il.Create(OpCodes.Ldarg_0),
                        il.Create(OpCodes.Newobj, refs.WeakCtor),
                        il.Create(OpCodes.Callvirt, refs.SetItem),
                    })
                    {
                        il.InsertAfter(after, add);
                        after = add;
                    }
                    pinned = true;
                }
            }
            if (!pinned) return $"{ctor.FullName} does not set {handle.Name}";
        }
        if (trampolines.Count == 0) return "the constructor builds no instance delegates";

        // Finalizer: if (m_pGCHandle.IsAllocated) recomp_instances.Remove(m_pGCHandle.AddrOfPinnedObject());
        // ahead of its own code, which frees the handle.
        var fil = finalizer.Body.GetILProcessor();
        var start = finalizer.Body.Instructions[0];
        foreach (var add in new[]
        {
            fil.Create(OpCodes.Ldarg_0),
            fil.Create(OpCodes.Ldflda, handle),
            fil.Create(OpCodes.Call, isAllocated),
            fil.Create(OpCodes.Brfalse, start),
            fil.Create(OpCodes.Ldsfld, map),
            fil.Create(OpCodes.Ldarg_0),
            fil.Create(OpCodes.Ldflda, handle),
            fil.Create(OpCodes.Call, addr),
            fil.Create(OpCodes.Box, refs.IntPtr),
            fil.Create(OpCodes.Callvirt, refs.Remove),
        })
            fil.InsertBefore(start, add);
        finalizer.Body.OptimizeMacros();

        Console.WriteLine($"responders: {type.FullName}: {trampolines.Count} static callbacks ({string.Join(", ", trampolines.Keys.Select(m => m.Name))})");
        return null;
    }

    // static void RecompOnX(IntPtr thisptr, args...)
    // {
    //     var w = recomp_instances[thisptr] as WeakReference;
    //     var t = w?.Target as Type;
    //     if (t != null) t.InternalOnX(thisptr, args...);
    // }
    static MethodDefinition Trampoline(TypeDefinition type, MethodDefinition target, TypeReference delegateType, FieldDefinition map, Refs refs)
    {
        if (target.Parameters.Count == 0 || target.Parameters[0].ParameterType.MetadataType != MetadataType.IntPtr)
            throw new InvalidOperationException($"{target.FullName}: the first parameter is not the thisptr");
        var m = new MethodDefinition("Recomp" + target.Name, MethodAttributes.Private | MethodAttributes.Static | MethodAttributes.HideBySig,
            target.ReturnType);
        foreach (var p in target.Parameters)
        {
            var copy = new ParameterDefinition(p.Name, p.Attributes, p.ParameterType);
            if (p.HasMarshalInfo) copy.MarshalInfo = p.MarshalInfo;
            m.Parameters.Add(copy);
        }
        var attribute = new CustomAttribute(refs.Attribute());
        attribute.ConstructorArguments.Add(new CustomAttributeArgument(refs.SystemType, delegateType));
        m.CustomAttributes.Add(attribute);
        var instance = new VariableDefinition(type);
        m.Body.Variables.Add(instance);
        m.Body.InitLocals = true;
        var il = m.Body.GetILProcessor();
        var ret = il.Create(OpCodes.Ret);
        il.Emit(OpCodes.Ldsfld, map);
        il.Emit(OpCodes.Ldarg_0);
        il.Emit(OpCodes.Box, refs.IntPtr);
        il.Emit(OpCodes.Callvirt, refs.GetItem);
        il.Emit(OpCodes.Isinst, refs.WeakReference);
        il.Emit(OpCodes.Dup);
        var noEntry = il.Create(OpCodes.Pop);
        il.Emit(OpCodes.Brfalse, noEntry);
        il.Emit(OpCodes.Callvirt, refs.GetTarget);
        il.Emit(OpCodes.Isinst, type);
        il.Emit(OpCodes.Stloc, instance);
        il.Emit(OpCodes.Ldloc, instance);
        il.Emit(OpCodes.Brfalse, ret);
        il.Emit(OpCodes.Ldloc, instance);
        for (int i = 0; i < m.Parameters.Count; i++) il.Emit(OpCodes.Ldarg, m.Parameters[i]);
        il.Emit(OpCodes.Call, target);
        il.Emit(OpCodes.Br, ret);
        il.Append(noEntry);
        il.Append(ret);
        m.Body.OptimizeMacros();
        type.Methods.Add(m);
        return m;
    }
}
