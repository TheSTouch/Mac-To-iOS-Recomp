// Harmony's attributes, with the same constructors as Harmony 2.4 so mods compiled against it
// resolve. They are only read at port time (asmtool harmony), never at run time.
using System;
using System.Collections.Generic;

namespace HarmonyLib
{
    public enum MethodType
    {
        Normal, Getter, Setter, Constructor, StaticConstructor, Enumerator, Async, Finalizer, EventAdd, EventRemove,
        OperatorImplicit, OperatorExplicit, OperatorUnaryPlus, OperatorUnaryNegation, OperatorLogicalNot,
        OperatorOnesComplement, OperatorIncrement, OperatorDecrement, OperatorTrue, OperatorFalse, OperatorAddition,
        OperatorSubtraction, OperatorMultiply, OperatorDivision, OperatorModulus, OperatorBitwiseAnd, OperatorBitwiseOr,
        OperatorExclusiveOr, OperatorLeftShift, OperatorRightShift, OperatorEquality, OperatorInequality,
        OperatorGreaterThan, OperatorLessThan, OperatorGreaterThanOrEqual, OperatorLessThanOrEqual, OperatorComma,
    }

    public enum ArgumentType { Normal, Ref, Out, Pointer }

    public enum HarmonyPatchType { All, Prefix, Postfix, Transpiler, Finalizer, ReversePatch, InnerPrefix, InnerPostfix }

    public enum HarmonyReversePatchType { Original, Snapshot }

    public static class Priority
    {
        public const int Last = 0;
        public const int VeryLow = 100;
        public const int Low = 200;
        public const int LowerThanNormal = 300;
        public const int Normal = 400;
        public const int HigherThanNormal = 500;
        public const int High = 600;
        public const int VeryHigh = 700;
        public const int First = 800;
    }

    public class HarmonyAttribute : Attribute
    {
        public HarmonyMethod info = new HarmonyMethod();
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method | AttributeTargets.Delegate, AllowMultiple = true)]
    public class HarmonyPatch : HarmonyAttribute
    {
        public HarmonyPatch() { }
        public HarmonyPatch(Type declaringType) { info.declaringType = declaringType; }
        public HarmonyPatch(Type declaringType, Type[] argumentTypes) { info.declaringType = declaringType; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type declaringType, string methodName) { info.declaringType = declaringType; info.methodName = methodName; }
        public HarmonyPatch(Type declaringType, string methodName, params Type[] argumentTypes) { info.declaringType = declaringType; info.methodName = methodName; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type declaringType, string methodName, Type[] argumentTypes, ArgumentType[] argumentVariations) { info.declaringType = declaringType; info.methodName = methodName; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type declaringType, MethodType methodType) { info.declaringType = declaringType; info.methodType = methodType; }
        public HarmonyPatch(Type declaringType, MethodType methodType, params Type[] argumentTypes) { info.declaringType = declaringType; info.methodType = methodType; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type declaringType, MethodType methodType, Type[] argumentTypes, ArgumentType[] argumentVariations) { info.declaringType = declaringType; info.methodType = methodType; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type declaringType, string methodName, MethodType methodType) { info.declaringType = declaringType; info.methodName = methodName; info.methodType = methodType; }
        public HarmonyPatch(string methodName) { info.methodName = methodName; }
        public HarmonyPatch(string methodName, params Type[] argumentTypes) { info.methodName = methodName; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(string methodName, Type[] argumentTypes, ArgumentType[] argumentVariations) { info.methodName = methodName; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(string methodName, MethodType methodType) { info.methodName = methodName; info.methodType = methodType; }
        public HarmonyPatch(MethodType methodType) { info.methodType = methodType; }
        public HarmonyPatch(MethodType methodType, params Type[] argumentTypes) { info.methodType = methodType; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(MethodType methodType, Type[] argumentTypes, ArgumentType[] argumentVariations) { info.methodType = methodType; info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type[] argumentTypes) { info.argumentTypes = argumentTypes; }
        public HarmonyPatch(Type[] argumentTypes, ArgumentType[] argumentVariations) { info.argumentTypes = argumentTypes; }
        public HarmonyPatch(string typeName, string methodName, MethodType methodType = MethodType.Normal) { info.declaringType = AccessTools.TypeByName(typeName); info.methodName = methodName; info.methodType = methodType; }
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct)]
    public class HarmonyPatchAll : HarmonyAttribute { }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct)]
    public class HarmonyPatchCategory : HarmonyAttribute
    {
        public HarmonyPatchCategory(string category) { info.category = category; }
    }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyPrefix : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyPostfix : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyTranspiler : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyFinalizer : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyPrepare : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyCleanup : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyTargetMethod : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyTargetMethods : Attribute { }

    [AttributeUsage(AttributeTargets.Method)]
    public class HarmonyReversePatch : HarmonyAttribute
    {
        public HarmonyReversePatch(HarmonyReversePatchType type = HarmonyReversePatchType.Original) { info.reversePatchType = type; }
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method)]
    public class HarmonyPriority : HarmonyAttribute
    {
        public HarmonyPriority(int priority) { info.priority = priority; }
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method)]
    public class HarmonyBefore : HarmonyAttribute
    {
        public HarmonyBefore(params string[] before) { info.before = before; }
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method)]
    public class HarmonyAfter : HarmonyAttribute
    {
        public HarmonyAfter(params string[] after) { info.after = after; }
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method)]
    public class HarmonyDebug : HarmonyAttribute
    {
        public HarmonyDebug() { info.debug = true; }
    }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method)]
    public class HarmonyWrapSafe : HarmonyAttribute { }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct | AttributeTargets.Method | AttributeTargets.Parameter, AllowMultiple = true)]
    public class HarmonyArgument : Attribute
    {
        public string OriginalName { get; private set; }
        public int Index { get; private set; }
        public string NewName { get; private set; }

        public HarmonyArgument(string originalName) : this(originalName, null) { }
        public HarmonyArgument(int index) : this(index, null) { }
        public HarmonyArgument(string originalName, string newName) { OriginalName = originalName; Index = -1; NewName = newName; }
        public HarmonyArgument(int index, string name) { OriginalName = null; Index = index; NewName = name; }
    }

    public class HarmonyMethod
    {
        public System.Reflection.MethodInfo method;
        public string category;
        public Type declaringType;
        public string methodName;
        public MethodType? methodType;
        public Type[] argumentTypes;
        public int priority = -1;
        public string[] before;
        public string[] after;
        public HarmonyReversePatchType? reversePatchType;
        public bool? debug;
        public bool nonVirtualDelegate;

        public HarmonyMethod() { }
        public HarmonyMethod(System.Reflection.MethodInfo method) { this.method = method; }
        public HarmonyMethod(Delegate @delegate) : this(@delegate.Method) { }
        public HarmonyMethod(System.Reflection.MethodInfo method, int priority = -1, string[] before = null, string[] after = null, bool? debug = null)
        {
            this.method = method; this.priority = priority; this.before = before; this.after = after; this.debug = debug;
        }
        public HarmonyMethod(Delegate @delegate, int priority = -1, string[] before = null, string[] after = null, bool? debug = null)
            : this(@delegate.Method, priority, before, after, debug) { }
        public HarmonyMethod(Type methodType, string methodName, Type[] argumentTypes = null)
            : this(AccessTools.Method(methodType, methodName, argumentTypes)) { }

        public static List<string> HarmonyFields() => new List<string> { "method", "category", "declaringType", "methodName", "methodType", "argumentTypes", "priority", "before", "after", "reversePatchType", "debug", "nonVirtualDelegate" };

        public override string ToString() => method != null ? $"{method.DeclaringType}.{method.Name}" : $"{declaringType}.{methodName}";

        public static implicit operator HarmonyMethod(System.Reflection.MethodInfo method) => new HarmonyMethod(method);
        public static implicit operator HarmonyMethod(Delegate @delegate) => new HarmonyMethod(@delegate);
    }
}
