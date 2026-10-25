// The reflection helpers of Harmony that mods use outside patches, with Harmony's signatures
// and lookup rules. Plain reflection, which IL2CPP supports. Helpers that need generated code
// (FieldRefAccess, MethodDelegate with virtualCall: false) are left out: a mod that calls one
// fails the port-time check (asmtool check) and is reported instead of crashing on the iPad.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

namespace HarmonyLib
{
    public static class AccessTools
    {
        public static readonly BindingFlags all = BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic |
                                                  BindingFlags.GetField | BindingFlags.SetField | BindingFlags.GetProperty | BindingFlags.SetProperty;
        public static readonly BindingFlags allDeclared = all | BindingFlags.DeclaredOnly;

        public static IEnumerable<Assembly> AllAssemblies() =>
            AppDomain.CurrentDomain.GetAssemblies().Where(a => !a.FullName.StartsWith("Microsoft.VisualStudio"));

        public static Type TypeByName(string name)
        {
            var type = Type.GetType(name, false);
            if (type != null) return type;
            foreach (var assembly in AllAssemblies())
            {
                type = assembly.GetType(name, false);
                if (type != null) return type;
            }
            return AllTypes().FirstOrDefault(t => t.FullName == name || t.Name == name);
        }

        public static Type[] GetTypesFromAssembly(Assembly assembly)
        {
            try { return assembly.GetTypes(); }
            catch (ReflectionTypeLoadException e) { return e.Types.Where(t => t != null).ToArray(); }
        }

        public static IEnumerable<Type> AllTypes() => AllAssemblies().SelectMany(GetTypesFromAssembly);

        public static IEnumerable<Type> InnerTypes(Type type) => type.GetNestedTypes(all);

        public static T FindIncludingBaseTypes<T>(Type type, Func<Type, T> func) where T : class
        {
            for (; type != null; type = type.BaseType)
            {
                var result = func(type);
                if (result != null) return result;
            }
            return null;
        }

        public static T FindIncludingInnerTypes<T>(Type type, Func<Type, T> func) where T : class
        {
            var result = func(type);
            if (result != null) return result;
            foreach (var inner in type.GetNestedTypes(all))
            {
                result = FindIncludingInnerTypes(inner, func);
                if (result != null) return result;
            }
            return null;
        }

        static (Type type, string name) TypeColonName(string typeColonName)
        {
            if (typeColonName == null) throw new ArgumentNullException(nameof(typeColonName));
            var parts = typeColonName.Split(':');
            if (parts.Length != 2) throw new ArgumentException($" must be specified as 'Namespace.Type1.Type2:MemberName", nameof(typeColonName));
            return (TypeByName(parts[0]), parts[1]);
        }

        public static FieldInfo DeclaredField(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : type.GetField(name, allDeclared);

        public static FieldInfo DeclaredField(string typeColonName) { var (t, n) = TypeColonName(typeColonName); return DeclaredField(t, n); }

        public static FieldInfo Field(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : FindIncludingBaseTypes(type, t => t.GetField(name, all));

        public static FieldInfo Field(string typeColonName) { var (t, n) = TypeColonName(typeColonName); return Field(t, n); }

        public static FieldInfo DeclaredField(Type type, int idx) => type == null ? null : GetDeclaredFields(type).ElementAtOrDefault(idx);

        public static PropertyInfo DeclaredProperty(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : type.GetProperty(name, allDeclared);

        public static PropertyInfo DeclaredProperty(string typeColonName) { var (t, n) = TypeColonName(typeColonName); return DeclaredProperty(t, n); }

        public static MethodInfo DeclaredPropertyGetter(Type type, string name) => DeclaredProperty(type, name)?.GetGetMethod(true);

        public static MethodInfo DeclaredPropertyGetter(string typeColonName) => DeclaredProperty(typeColonName)?.GetGetMethod(true);

        public static MethodInfo DeclaredPropertySetter(Type type, string name) => DeclaredProperty(type, name)?.GetSetMethod(true);

        public static MethodInfo DeclaredPropertySetter(string typeColonName) => DeclaredProperty(typeColonName)?.GetSetMethod(true);

        public static PropertyInfo Property(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : FindIncludingBaseTypes(type, t => t.GetProperty(name, all));

        public static PropertyInfo Property(string typeColonName) { var (t, n) = TypeColonName(typeColonName); return Property(t, n); }

        public static MethodInfo PropertyGetter(Type type, string name) => Property(type, name)?.GetGetMethod(true);

        public static MethodInfo PropertyGetter(string typeColonName) => Property(typeColonName)?.GetGetMethod(true);

        public static MethodInfo PropertySetter(Type type, string name) => Property(type, name)?.GetSetMethod(true);

        public static MethodInfo PropertySetter(string typeColonName) => Property(typeColonName)?.GetSetMethod(true);

        public static EventInfo DeclaredEvent(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : type.GetEvent(name, allDeclared);

        public static EventInfo Event(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : FindIncludingBaseTypes(type, t => t.GetEvent(name, all));

        public static MethodInfo EventAdder(Type type, string name) => Event(type, name)?.GetAddMethod(true);

        public static MethodInfo EventRemover(Type type, string name) => Event(type, name)?.GetRemoveMethod(true);

        public static MethodInfo DeclaredMethod(Type type, string name, Type[] parameters = null, Type[] generics = null)
        {
            if (type == null || string.IsNullOrEmpty(name)) return null;
            var method = parameters != null ? type.GetMethod(name, allDeclared, null, parameters, new ParameterModifier[0]) : type.GetMethod(name, allDeclared);
            return method != null && generics != null ? method.MakeGenericMethod(generics) : method;
        }

        public static MethodInfo DeclaredMethod(string typeColonName, Type[] parameters = null, Type[] generics = null)
        {
            var (t, n) = TypeColonName(typeColonName);
            return DeclaredMethod(t, n, parameters, generics);
        }

        public static MethodInfo Method(Type type, string name, Type[] parameters = null, Type[] generics = null)
        {
            if (type == null || string.IsNullOrEmpty(name)) return null;
            var modifiers = new ParameterModifier[0];
            MethodInfo method;
            if (parameters == null)
            {
                try { method = FindIncludingBaseTypes(type, t => t.GetMethod(name, all)); }
                catch (AmbiguousMatchException e)
                {
                    method = FindIncludingBaseTypes(type, t => t.GetMethod(name, all, null, Type.EmptyTypes, modifiers));
                    if (method == null) throw new AmbiguousMatchException($"Ambiguous match in Harmony patch for {type}:{name}", e);
                }
            }
            else
            {
                method = FindIncludingBaseTypes(type, t => t.GetMethod(name, all, null, parameters, modifiers));
            }
            return method != null && generics != null ? method.MakeGenericMethod(generics) : method;
        }

        public static MethodInfo Method(string typeColonName, Type[] parameters = null, Type[] generics = null)
        {
            var (t, n) = TypeColonName(typeColonName);
            return Method(t, n, parameters, generics);
        }

        public static List<string> GetMethodNames(Type type) => type == null ? new List<string>() : GetDeclaredMethods(type).Select(m => m.Name).ToList();

        public static List<string> GetMethodNames(object instance) => instance == null ? new List<string>() : GetMethodNames(instance.GetType());

        public static List<string> GetFieldNames(Type type) => type == null ? new List<string>() : GetDeclaredFields(type).Select(f => f.Name).ToList();

        public static List<string> GetFieldNames(object instance) => instance == null ? new List<string>() : GetFieldNames(instance.GetType());

        public static List<string> GetPropertyNames(Type type) => type == null ? new List<string>() : GetDeclaredProperties(type).Select(p => p.Name).ToList();

        public static List<string> GetPropertyNames(object instance) => instance == null ? new List<string>() : GetPropertyNames(instance.GetType());

        public static ConstructorInfo DeclaredConstructor(Type type, Type[] parameters = null, bool searchForStatic = false)
        {
            if (type == null) return null;
            var flags = searchForStatic ? allDeclared & ~BindingFlags.Instance : allDeclared & ~BindingFlags.Static;
            return type.GetConstructor(flags, null, parameters ?? Type.EmptyTypes, new ParameterModifier[0]);
        }

        public static ConstructorInfo Constructor(Type type, Type[] parameters = null, bool searchForStatic = false)
        {
            if (type == null) return null;
            var flags = searchForStatic ? all & ~BindingFlags.Instance : all & ~BindingFlags.Static;
            return FindIncludingBaseTypes(type, t => t.GetConstructor(flags, null, parameters ?? Type.EmptyTypes, new ParameterModifier[0]));
        }

        public static List<ConstructorInfo> GetDeclaredConstructors(Type type, bool? searchForStatic = null)
        {
            if (type == null) return new List<ConstructorInfo>();
            var flags = allDeclared;
            if (searchForStatic.HasValue) flags &= searchForStatic.Value ? ~BindingFlags.Instance : ~BindingFlags.Static;
            return type.GetConstructors(flags).Where(c => c.DeclaringType == type).ToList();
        }

        public static List<MethodInfo> GetDeclaredMethods(Type type) => type == null ? new List<MethodInfo>() : type.GetMethods(allDeclared).ToList();

        public static List<PropertyInfo> GetDeclaredProperties(Type type) => type == null ? new List<PropertyInfo>() : type.GetProperties(allDeclared).ToList();

        public static List<FieldInfo> GetDeclaredFields(Type type) => type == null ? new List<FieldInfo>() : type.GetFields(allDeclared).ToList();

        public static Type GetReturnedType(MethodBase methodOrConstructor) => methodOrConstructor is MethodInfo m ? m.ReturnType : typeof(void);

        public static Type Inner(Type type, string name) => type == null || string.IsNullOrEmpty(name) ? null : FindIncludingBaseTypes(type, t => t.GetNestedType(name, all));

        public static Type FirstInner(Type type, Func<Type, bool> predicate) => type?.GetNestedTypes(all).FirstOrDefault(predicate);

        public static MethodInfo FirstMethod(Type type, Func<MethodInfo, bool> predicate) => type?.GetMethods(allDeclared).FirstOrDefault(predicate);

        public static ConstructorInfo FirstConstructor(Type type, Func<ConstructorInfo, bool> predicate) => type?.GetConstructors(allDeclared).FirstOrDefault(predicate);

        public static PropertyInfo FirstProperty(Type type, Func<PropertyInfo, bool> predicate) => type?.GetProperties(allDeclared).FirstOrDefault(predicate);

        public static Type[] GetTypes(object[] parameters) => parameters == null ? Type.EmptyTypes : parameters.Select(p => p?.GetType() ?? typeof(object)).ToArray();

        public static DelegateType MethodDelegate<DelegateType>(MethodInfo method, object instance = null, bool virtualCall = true, Type[] delegateArgs = null) where DelegateType : Delegate
        {
            return (DelegateType)(method.IsStatic || instance == null
                ? Delegate.CreateDelegate(typeof(DelegateType), method)
                : Delegate.CreateDelegate(typeof(DelegateType), instance, method));
        }

        public static object GetDefaultValue(Type type) => type == null || type == typeof(void) || !type.IsValueType ? null : Activator.CreateInstance(type);

        public static object CreateInstance(Type type)
        {
            if (type == null) throw new ArgumentNullException(nameof(type));
            var ctor = type.GetConstructor(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic, null, Type.EmptyTypes, null);
            return ctor != null ? ctor.Invoke(null) : System.Runtime.Serialization.FormatterServices.GetUninitializedObject(type);
        }

        public static T CreateInstance<T>() => (T)CreateInstance(typeof(T));

        public static void ThrowMissingMemberException(Type type, params string[] names) =>
            throw new MissingMemberException($"{string.Join(",", names)}; available fields: {string.Join(",", GetFieldNames(type))}; available properties: {string.Join(",", GetPropertyNames(type))}");

        public static bool IsStruct(Type type) => type != null && type.IsValueType && !type.IsPrimitive && !type.IsEnum && type != typeof(void);

        public static bool IsClass(Type type) => type != null && !type.IsValueType;

        public static bool IsValue(Type type) => type != null && (type.IsPrimitive || type.IsEnum);

        public static bool IsVoid(Type type) => type == typeof(void);

        public static bool IsStatic(MemberInfo member) => member switch
        {
            Type t => t.IsAbstract && t.IsSealed,
            FieldInfo f => f.IsStatic,
            MethodBase m => m.IsStatic,
            PropertyInfo p => (p.GetGetMethod(true) ?? p.GetSetMethod(true)).IsStatic,
            EventInfo e => e.GetAddMethod(true).IsStatic,
            _ => throw new ArgumentException($"Unknown member type: {member?.GetType()}"),
        };
    }

    public class Traverse
    {
        readonly Type _type;
        readonly object _root;
        readonly MemberInfo _info;
        readonly MethodBase _method;
        readonly object[] _params;

        public static Traverse Create(Type type) => new Traverse(type);
        public static Traverse Create<T>() => Create(typeof(T));
        public static Traverse Create(object root) => new Traverse(root);
        public static Traverse CreateWithType(string name) => new Traverse(AccessTools.TypeByName(name));

        Traverse() { }
        public Traverse(Type type) { _type = type; }
        public Traverse(object root) { _root = root; _type = root?.GetType(); }

        Traverse(object root, MemberInfo info, object[] index) { _root = root; _type = root?.GetType() ?? info.GetUnderlyingType(); _info = info; _params = index; }

        Traverse(object root, MethodInfo method, object[] parameters) { _root = root; _type = method.ReturnType; _method = method; _params = parameters; }

        public bool IsField => _info is FieldInfo;
        public bool IsProperty => _info is PropertyInfo;

        public object GetValue()
        {
            if (_info is FieldInfo f) return f.GetValue(_root);
            if (_info is PropertyInfo p) return p.GetValue(_root, AccessTools.all, null, _params, null);
            if (_method != null) return _method.Invoke(_root, _params);
            return _root == null && _type != null ? _type : _root;
        }

        public T GetValue<T>() => GetValue() is T value ? value : default;

        public object GetValue(params object[] arguments) => _method == null ? throw new InvalidOperationException("cannot get method value without method") : _method.Invoke(_root, arguments);

        public T GetValue<T>(params object[] arguments) => GetValue(arguments) is T value ? value : default;

        public Traverse SetValue(object value)
        {
            if (_info is FieldInfo f) f.SetValue(_root, value, AccessTools.all, null, null);
            if (_info is PropertyInfo p) p.SetValue(_root, value, AccessTools.all, null, _params, null);
            if (_method != null) throw new InvalidOperationException($"cannot set value of method {_method}");
            return this;
        }

        public Type GetValueType() => _info is FieldInfo f ? f.FieldType : _info is PropertyInfo p ? p.PropertyType : _method is MethodInfo m ? m.ReturnType : _type;

        Traverse Resolve() => _root == null && _type != null ? this : new Traverse(GetValue());

        public Traverse Type(string name)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            var type = _type == null ? null : AccessTools.Inner(_type, name);
            return type == null ? new Traverse() : Create(type);
        }

        public Traverse Field(string name)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            var resolved = Resolve();
            if (resolved._type == null) return new Traverse();
            var field = AccessTools.Field(resolved._type, name);
            return field == null || (!field.IsStatic && resolved._root == null) ? new Traverse() : new Traverse(resolved._root, field, null);
        }

        public Traverse<T> Field<T>(string name) => new Traverse<T>(Field(name));

        public List<string> Fields() => AccessTools.GetFieldNames(Resolve()._type);

        public Traverse Property(string name, object[] index = null)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            var resolved = Resolve();
            if (resolved._type == null) return new Traverse();
            var property = AccessTools.Property(resolved._type, name);
            return property == null ? new Traverse() : new Traverse(resolved._root, property, index);
        }

        public Traverse<T> Property<T>(string name, object[] index = null) => new Traverse<T>(Property(name, index));

        public List<string> Properties() => AccessTools.GetPropertyNames(Resolve()._type);

        public Traverse Method(string name, params object[] arguments)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            var resolved = Resolve();
            if (resolved._type == null) return new Traverse();
            var method = AccessTools.Method(resolved._type, name, AccessTools.GetTypes(arguments));
            return method == null ? new Traverse() : new Traverse(resolved._root, method, arguments);
        }

        public Traverse Method(string name, Type[] paramTypes, object[] arguments = null)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            var resolved = Resolve();
            if (resolved._type == null) return new Traverse();
            var method = AccessTools.Method(resolved._type, name, paramTypes);
            return method == null ? new Traverse() : new Traverse(resolved._root, method, arguments);
        }

        public List<string> Methods() => AccessTools.GetMethodNames(Resolve()._type);

        public bool FieldExists() => _info is FieldInfo;
        public bool PropertyExists() => _info is PropertyInfo;
        public bool MethodExists() => _method != null;
        public bool TypeExists() => _type != null;

        public override string ToString() => (_method ?? GetValue())?.ToString();
    }

    public class Traverse<T>
    {
        readonly Traverse traverse;

        Traverse() { }

        public Traverse(Traverse traverse) { this.traverse = traverse; }

        public T Value
        {
            get => traverse.GetValue<T>();
            set => traverse.SetValue(value);
        }
    }

    static class MemberInfoExtensions
    {
        internal static Type GetUnderlyingType(this MemberInfo member) => member switch
        {
            EventInfo e => e.EventHandlerType,
            FieldInfo f => f.FieldType,
            MethodInfo m => m.ReturnType,
            PropertyInfo p => p.PropertyType,
            _ => throw new ArgumentException("Member must be of type EventInfo, FieldInfo, MethodInfo, or PropertyInfo"),
        };
    }
}
