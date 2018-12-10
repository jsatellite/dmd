/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2018 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/semantic3.d, _semantic3.d)
 * Documentation:  https://dlang.org/phobos/dmd_semantic3.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/semantic3.d
 */

module dmd.semantic3;

import core.stdc.stdio;
import core.stdc.string;

import dmd.aggregate;
import dmd.aliasthis;
import dmd.arraytypes;
import dmd.astcodegen;
import dmd.attrib;
import dmd.blockexit;
import dmd.clone;
import dmd.ctorflow;
import dmd.dcast;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dimport;
import dmd.dinterpret;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.dversion;
import dmd.errors;
import dmd.escape;
import dmd.expression;
import dmd.expressionsem;
import dmd.func;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.initsem;
import dmd.hdrgen;
import dmd.mtype;
import dmd.nogc;
import dmd.nspace;
import dmd.objc;
import dmd.opover;
import dmd.parse;
import dmd.root.filename;
import dmd.root.outbuffer;
import dmd.root.rmem;
import dmd.root.rootobject;
import dmd.sideeffect;
import dmd.statementsem;
import dmd.staticassert;
import dmd.tokens;
import dmd.utf;
import dmd.utils;
import dmd.semantic2;
import dmd.statement;
import dmd.target;
import dmd.templateparamsem;
import dmd.typesem;
import dmd.visitor;

enum LOG = false;


/*************************************
 * Does semantic analysis on function bodies.
 */
extern(C++) void semantic3(Dsymbol dsym, Scope* sc)
{
    scope v = new Semantic3Visitor(sc);
    dsym.accept(v);
}

private extern(C++) final class Semantic3Visitor : Visitor
{
    alias visit = Visitor.visit;

    Scope* sc;
    this(Scope* sc)
    {
        this.sc = sc;
    }

    override void visit(Dsymbol) {}

    override void visit(TemplateInstance tempinst)
    {
        static if (LOG)
        {
            printf("TemplateInstance.semantic3('%s'), semanticRun = %d\n", tempinst.toChars(), tempinst.semanticRun);
        }
        //if (toChars()[0] == 'D') *(char*)0=0;
        if (tempinst.semanticRun >= PASS.semantic3)
            return;
        tempinst.semanticRun = PASS.semantic3;
        if (!tempinst.errors && tempinst.members)
        {
            TemplateDeclaration tempdecl = tempinst.tempdecl.isTemplateDeclaration();
            assert(tempdecl);

            sc = tempdecl._scope;
            sc = sc.push(tempinst.argsym);
            sc = sc.push(tempinst);
            sc.tinst = tempinst;
            sc.minst = tempinst.minst;

            int needGagging = (tempinst.gagged && !global.gag);
            uint olderrors = global.errors;
            int oldGaggedErrors = -1; // dead-store to prevent spurious warning
            /* If this is a gagged instantiation, gag errors.
             * Future optimisation: If the results are actually needed, errors
             * would already be gagged, so we don't really need to run semantic
             * on the members.
             */
            if (needGagging)
                oldGaggedErrors = global.startGagging();

            for (size_t i = 0; i < tempinst.members.dim; i++)
            {
                Dsymbol s = (*tempinst.members)[i];
                s.semantic3(sc);
                if (tempinst.gagged && global.errors != olderrors)
                    break;
            }

            if (global.errors != olderrors)
            {
                if (!tempinst.errors)
                {
                    if (!tempdecl.literal)
                        tempinst.error(tempinst.loc, "error instantiating");
                    if (tempinst.tinst)
                        tempinst.tinst.printInstantiationTrace();
                }
                tempinst.errors = true;
            }
            if (needGagging)
                global.endGagging(oldGaggedErrors);

            sc = sc.pop();
            sc.pop();
        }
    }

    override void visit(TemplateMixin tmix)
    {
        if (tmix.semanticRun >= PASS.semantic3)
            return;
        tmix.semanticRun = PASS.semantic3;
        static if (LOG)
        {
            printf("TemplateMixin.semantic3('%s')\n", tmix.toChars());
        }
        if (tmix.members)
        {
            sc = sc.push(tmix.argsym);
            sc = sc.push(tmix);
            for (size_t i = 0; i < tmix.members.dim; i++)
            {
                Dsymbol s = (*tmix.members)[i];
                s.semantic3(sc);
            }
            sc = sc.pop();
            sc.pop();
        }
    }

    override void visit(Module mod)
    {
        //printf("Module::semantic3('%s'): parent = %p\n", toChars(), parent);
        if (mod.semanticRun != PASS.semantic2done)
            return;
        mod.semanticRun = PASS.semantic3;
        // Note that modules get their own scope, from scratch.
        // This is so regardless of where in the syntax a module
        // gets imported, it is unaffected by context.
        Scope* sc = Scope.createGlobal(mod); // create root scope
        //printf("Module = %p\n", sc.scopesym);
        // Pass 3 semantic routines: do initializers and function bodies
        for (size_t i = 0; i < mod.members.dim; i++)
        {
            Dsymbol s = (*mod.members)[i];
            //printf("Module %s: %s.semantic3()\n", toChars(), s.toChars());
            s.semantic3(sc);

            mod.runDeferredSemantic2();
        }
        if (mod.userAttribDecl)
        {
            mod.userAttribDecl.semantic3(sc);
        }
        sc = sc.pop();
        sc.pop();
        mod.semanticRun = PASS.semantic3done;
    }

    override void visit(FuncDeclaration funcdecl)
    {
        /* Determine if function should add `return 0;`
         */
        bool addReturn0()
        {
            TypeFunction f = cast(TypeFunction)funcdecl.type;

            return f.next.ty == Tvoid &&
                (funcdecl.isMain() || global.params.betterC && funcdecl.isCMain());
        }

        VarDeclaration _arguments = null;

        if (!funcdecl.parent)
        {
            if (global.errors)
                return;
            //printf("FuncDeclaration::semantic3(%s '%s', sc = %p)\n", kind(), toChars(), sc);
            assert(0);
        }
        if (funcdecl.errors || isError(funcdecl.parent))
        {
            funcdecl.errors = true;
            return;
        }
        //printf("FuncDeclaration::semantic3('%s.%s', %p, sc = %p, loc = %s)\n", funcdecl.parent.toChars(), funcdecl.toChars(), funcdecl, sc, funcdecl.loc.toChars());
        //fflush(stdout);
        //printf("storage class = x%x %x\n", sc.stc, storage_class);
        //{ static int x; if (++x == 2) *(char*)0=0; }
        //printf("\tlinkage = %d\n", sc.linkage);

        if (funcdecl.ident == Id.assign && !funcdecl.inuse)
        {
            if (funcdecl.storage_class & STC.inference)
            {
                /* https://issues.dlang.org/show_bug.cgi?id=15044
                 * For generated opAssign function, any errors
                 * from its body need to be gagged.
                 */
                uint oldErrors = global.startGagging();
                ++funcdecl.inuse;
                funcdecl.semantic3(sc);
                --funcdecl.inuse;
                if (global.endGagging(oldErrors))   // if errors happened
                {
                    // Disable generated opAssign, because some members forbid identity assignment.
                    funcdecl.storage_class |= STC.disable;
                    funcdecl.fbody = null;   // remove fbody which contains the error
                    funcdecl.semantic3Errors = false;
                }
                return;
            }
        }

        //printf(" sc.incontract = %d\n", (sc.flags & SCOPE.contract));
        if (funcdecl.semanticRun >= PASS.semantic3)
            return;
        funcdecl.semanticRun = PASS.semantic3;
        funcdecl.semantic3Errors = false;

        if (!funcdecl.type || funcdecl.type.ty != Tfunction)
            return;
        TypeFunction f = cast(TypeFunction)funcdecl.type;
        if (!funcdecl.inferRetType && f.next.ty == Terror)
            return;

        if (!funcdecl.fbody && funcdecl.inferRetType && !f.next)
        {
            funcdecl.error("has no function body with return type inference");
            return;
        }

        uint oldErrors = global.errors;
        auto fds = FuncDeclSem3(funcdecl,sc);

        fds.checkInContractOverrides();

        // Remember whether we need to generate an 'out' contract.
        immutable bool needEnsure = FuncDeclaration.needsFensure(funcdecl);

        if (funcdecl.fbody || funcdecl.frequires || needEnsure)
        {
            /* Symbol table into which we place parameters and nested functions,
             * solely to diagnose name collisions.
             */
            funcdecl.localsymtab = new DsymbolTable();

            // Establish function scope
            auto ss = new ScopeDsymbol();
            // find enclosing scope symbol, might skip symbol-less CTFE and/or FuncExp scopes
            for (auto scx = sc; ; scx = scx.enclosing)
            {
                if (scx.scopesym)
                {
                    ss.parent = scx.scopesym;
                    break;
                }
            }
            ss.loc = funcdecl.loc;
            ss.endlinnum = funcdecl.endloc.linnum;
            Scope* sc2 = sc.push(ss);
            sc2.func = funcdecl;
            sc2.parent = funcdecl;
            sc2.ctorflow.callSuper = CSX.none;
            sc2.sbreak = null;
            sc2.scontinue = null;
            sc2.sw = null;
            sc2.fes = funcdecl.fes;
            sc2.linkage = LINK.d;
            sc2.stc &= ~(STC.auto_ | STC.scope_ | STC.static_ | STC.abstract_ | STC.deprecated_ | STC.override_ | STC.TYPECTOR | STC.final_ | STC.tls | STC.gshared | STC.ref_ | STC.return_ | STC.property | STC.nothrow_ | STC.pure_ | STC.safe | STC.trusted | STC.system);
            sc2.protection = Prot(Prot.Kind.public_);
            sc2.explicitProtection = 0;
            sc2.aligndecl = null;
            if (funcdecl.ident != Id.require && funcdecl.ident != Id.ensure)
                sc2.flags = sc.flags & ~SCOPE.contract;
            sc2.flags &= ~SCOPE.compile;
            sc2.tf = null;
            sc2.os = null;
            sc2.inLoop = false;
            sc2.userAttribDecl = null;
            if (sc2.intypeof == 1)
                sc2.intypeof = 2;
            sc2.ctorflow.fieldinit = null;

            /* Note: When a lambda is defined immediately under aggregate member
             * scope, it should be contextless due to prevent interior pointers.
             * e.g.
             *      // dg points 'this' - it's interior pointer
             *      class C { int x; void delegate() dg = (){ this.x = 1; }; }
             *
             * However, lambdas could be used inside typeof, in order to check
             * some expressions validity at compile time. For such case the lambda
             * body can access aggregate instance members.
             * e.g.
             *      class C { int x; static assert(is(typeof({ this.x = 1; }))); }
             *
             * To properly accept it, mark these lambdas as member functions.
             */
            if (auto fld = funcdecl.isFuncLiteralDeclaration())
            {
                if (auto ad = funcdecl.isMember2())
                {
                    if (!sc.intypeof)
                    {
                        if (fld.tok == TOK.delegate_)
                            funcdecl.error("cannot be %s members", ad.kind());
                        else
                            fld.tok = TOK.function_;
                    }
                    else
                    {
                        if (fld.tok != TOK.function_)
                            fld.tok = TOK.delegate_;
                    }
                }
            }

            // Declare 'this'
            auto ad = funcdecl.isThis();
            funcdecl.vthis = funcdecl.declareThis(sc2, ad);
            //printf("[%s] ad = %p vthis = %p\n", loc.toChars(), ad, vthis);
            //if (vthis) printf("\tvthis.type = %s\n", vthis.type.toChars());

            // Declare hidden variable _arguments[] and _argptr
            if (f.varargs == 1)
            {
                if (f.linkage == LINK.d)
                {
                    // Declare _arguments[]
                    funcdecl.v_arguments = new VarDeclaration(Loc.initial, Type.typeinfotypelist.type, Id._arguments_typeinfo, null);
                    funcdecl.v_arguments.storage_class |= STC.temp | STC.parameter;
                    funcdecl.v_arguments.dsymbolSemantic(sc2);
                    sc2.insert(funcdecl.v_arguments);
                    funcdecl.v_arguments.parent = funcdecl;

                    //Type *t = Type::typeinfo.type.constOf().arrayOf();
                    Type t = Type.dtypeinfo.type.arrayOf();
                    _arguments = new VarDeclaration(Loc.initial, t, Id._arguments, null);
                    _arguments.storage_class |= STC.temp;
                    _arguments.dsymbolSemantic(sc2);
                    sc2.insert(_arguments);
                    _arguments.parent = funcdecl;
                }
                if (f.linkage == LINK.d || f.parameterList.length)
                {
                    // Declare _argptr
                    Type t = Type.tvalist;
                    // Init is handled in FuncDeclaration_toObjFile
                    funcdecl.v_argptr = new VarDeclaration(Loc.initial, t, Id._argptr, new VoidInitializer(funcdecl.loc));
                    funcdecl.v_argptr.storage_class |= STC.temp;
                    funcdecl.v_argptr.dsymbolSemantic(sc2);
                    sc2.insert(funcdecl.v_argptr);
                    funcdecl.v_argptr.parent = funcdecl;
                }
            }

            /* Declare all the function parameters as variables
             * and install them in parameters[]
             */
            size_t nparams = f.parameterList.length;
            if (nparams)
            {
                /* parameters[] has all the tuples removed, as the back end
                 * doesn't know about tuples
                 */
                funcdecl.parameters = new VarDeclarations();
                funcdecl.parameters.reserve(nparams);
                for (size_t i = 0; i < nparams; i++)
                {
                    Parameter fparam = f.parameterList[i];
                    Identifier id = fparam.ident;
                    StorageClass stc = 0;
                    if (!id)
                    {
                        /* Generate identifier for un-named parameter,
                         * because we need it later on.
                         */
                        fparam.ident = id = Identifier.generateId("_param_", i);
                        stc |= STC.temp;
                    }
                    Type vtype = fparam.type;
                    auto v = new VarDeclaration(funcdecl.loc, vtype, id, null);
                    //printf("declaring parameter %s of type %s\n", v.toChars(), v.type.toChars());
                    stc |= STC.parameter;
                    if (f.varargs == 2 && i + 1 == nparams)
                    {
                        stc |= STC.variadic;
                        auto vtypeb = vtype.toBasetype();
                        if (vtypeb.ty == Tarray)
                        {
                            /* Since it'll be pointing into the stack for the array
                             * contents, it needs to be `scope`
                             */
                            stc |= STC.scope_;
                        }
                    }
                    if (funcdecl.flags & FUNCFLAG.inferScope && !(fparam.storageClass & STC.scope_))
                        stc |= STC.maybescope;
                    stc |= fparam.storageClass & (STC.in_ | STC.out_ | STC.ref_ | STC.return_ | STC.scope_ | STC.lazy_ | STC.final_ | STC.TYPECTOR | STC.nodtor);
                    v.storage_class = stc;
                    v.dsymbolSemantic(sc2);
                    if (!sc2.insert(v))
                    {
                        funcdecl.error("parameter `%s.%s` is already defined", funcdecl.toChars(), v.toChars());
                        funcdecl.errors = true;
                    }
                    else
                        funcdecl.parameters.push(v);
                    funcdecl.localsymtab.insert(v);
                    v.parent = funcdecl;
                    if (fparam.userAttribDecl)
                        v.userAttribDecl = fparam.userAttribDecl;
                }
            }

            // Declare the tuple symbols and put them in the symbol table,
            // but not in parameters[].
            if (f.parameterList.parameters)
            {
                for (size_t i = 0; i < f.parameterList.parameters.dim; i++)
                {
                    Parameter fparam = (*f.parameterList.parameters)[i];
                    if (!fparam.ident)
                        continue; // never used, so ignore
                    if (fparam.type.ty == Ttuple)
                    {
                        TypeTuple t = cast(TypeTuple)fparam.type;
                        size_t dim = Parameter.dim(t.arguments);
                        auto exps = new Objects(dim);
                        for (size_t j = 0; j < dim; j++)
                        {
                            Parameter narg = Parameter.getNth(t.arguments, j);
                            assert(narg.ident);
                            VarDeclaration v = sc2.search(Loc.initial, narg.ident, null).isVarDeclaration();
                            assert(v);
                            Expression e = new VarExp(v.loc, v);
                            (*exps)[j] = e;
                        }
                        assert(fparam.ident);
                        auto v = new TupleDeclaration(funcdecl.loc, fparam.ident, exps);
                        //printf("declaring tuple %s\n", v.toChars());
                        v.isexp = true;
                        if (!sc2.insert(v))
                            funcdecl.error("parameter `%s.%s` is already defined", funcdecl.toChars(), v.toChars());
                        funcdecl.localsymtab.insert(v);
                        v.parent = funcdecl;
                    }
                }
            }

            // Precondition invariant
            Statement fpreinv = null;
            if (funcdecl.addPreInvariant())
            {
                Expression e = addInvariant(funcdecl.loc, sc, ad, funcdecl.vthis);
                if (e)
                    fpreinv = new ExpStatement(Loc.initial, e);
            }

            // Postcondition invariant
            Statement fpostinv = null;
            if (funcdecl.addPostInvariant())
            {
                Expression e = addInvariant(funcdecl.loc, sc, ad, funcdecl.vthis);
                if (e)
                    fpostinv = new ExpStatement(Loc.initial, e);
            }

            // Pre/Postcondition contract
            if (!funcdecl.fbody)
                funcdecl.buildEnsureRequire();

            Scope* scout = null;
            if (needEnsure || funcdecl.addPostInvariant())
            {
                /* https://issues.dlang.org/show_bug.cgi?id=3657
                 * Set the correct end line number for fensure scope.
                 */
                uint fensure_endlin = funcdecl.endloc.linnum;
                if (funcdecl.fensure)
                    if (auto s = funcdecl.fensure.isScopeStatement())
                        fensure_endlin = s.endloc.linnum;

                if ((needEnsure && global.params.useOut) || fpostinv)
                {
                    funcdecl.returnLabel = new LabelDsymbol(Id.returnLabel);
                }

                // scope of out contract (need for vresult.semantic)
                auto sym = new ScopeDsymbol();
                sym.parent = sc2.scopesym;
                sym.loc = funcdecl.loc;
                sym.endlinnum = fensure_endlin;
                scout = sc2.push(sym);
            }

            if (funcdecl.fbody)
            {
                auto sym = new ScopeDsymbol();
                sym.parent = sc2.scopesym;
                sym.loc = funcdecl.loc;
                sym.endlinnum = funcdecl.endloc.linnum;
                sc2 = sc2.push(sym);

                auto ad2 = funcdecl.isMember2();

                /* If this is a class constructor
                 */
                if (ad2 && funcdecl.isCtorDeclaration())
                {
                    sc2.ctorflow.allocFieldinit(ad2.fields.dim);
                    foreach (v; ad2.fields)
                    {
                        v.ctorinit = 0;
                    }
                }

                if (!funcdecl.inferRetType && !Target.isReturnOnStack(f, funcdecl.needThis()))
                    funcdecl.nrvo_can = 0;

                bool inferRef = (f.isref && (funcdecl.storage_class & STC.auto_));

                funcdecl.fbody = funcdecl.fbody.statementSemantic(sc2);
                if (!funcdecl.fbody)
                    funcdecl.fbody = new CompoundStatement(Loc.initial, new Statements());

                if (funcdecl.naked)
                {
                    fpreinv = null;         // can't accommodate with no stack frame
                    fpostinv = null;
                }

                assert(funcdecl.type == f || (funcdecl.type.ty == Tfunction && f.purity == PURE.impure && (cast(TypeFunction)funcdecl.type).purity >= PURE.fwdref));
                f = cast(TypeFunction)funcdecl.type;

                if (funcdecl.inferRetType)
                {
                    // If no return type inferred yet, then infer a void
                    if (!f.next)
                        f.next = Type.tvoid;
                    if (f.checkRetType(funcdecl.loc))
                        funcdecl.fbody = new ErrorStatement();
                }
                if (global.params.vcomplex && f.next !is null)
                    f.next.checkComplexTransition(funcdecl.loc, sc);

                if (funcdecl.returns && !funcdecl.fbody.isErrorStatement())
                {
                    for (size_t i = 0; i < funcdecl.returns.dim;)
                    {
                        Expression exp = (*funcdecl.returns)[i].exp;
                        if (exp.op == TOK.variable && (cast(VarExp)exp).var == funcdecl.vresult)
                        {
                            if (addReturn0())
                                exp.type = Type.tint32;
                            else
                                exp.type = f.next;
                            // Remove `return vresult;` from returns
                            funcdecl.returns.remove(i);
                            continue;
                        }
                        if (inferRef && f.isref && !exp.type.constConv(f.next)) // https://issues.dlang.org/show_bug.cgi?id=13336
                            f.isref = false;
                        i++;
                    }
                }
                if (f.isref) // Function returns a reference
                {
                    if (funcdecl.storage_class & STC.auto_)
                        funcdecl.storage_class &= ~STC.auto_;
                }
                if (!Target.isReturnOnStack(f, funcdecl.needThis()))
                    funcdecl.nrvo_can = 0;

                if (funcdecl.fbody.isErrorStatement())
                {
                }
                else if (funcdecl.isStaticCtorDeclaration())
                {
                    /* It's a static constructor. Ensure that all
                     * ctor consts were initialized.
                     */
                    ScopeDsymbol pd = funcdecl.toParent().isScopeDsymbol();
                    for (size_t i = 0; i < pd.members.dim; i++)
                    {
                        Dsymbol s = (*pd.members)[i];
                        s.checkCtorConstInit();
                    }
                }
                else if (ad2 && funcdecl.isCtorDeclaration())
                {
                    ClassDeclaration cd = ad2.isClassDeclaration();

                    // Verify that all the ctorinit fields got initialized
                    if (!(sc2.ctorflow.callSuper & CSX.this_ctor))
                    {
                        foreach (i, v; ad2.fields)
                        {
                            if (v.isThisDeclaration())
                                continue;
                            if (v.ctorinit == 0)
                            {
                                /* Current bugs in the flow analysis:
                                 * 1. union members should not produce error messages even if
                                 *    not assigned to
                                 * 2. structs should recognize delegating opAssign calls as well
                                 *    as delegating calls to other constructors
                                 */
                                if (v.isCtorinit() && !v.type.isMutable() && cd)
                                    funcdecl.error("missing initializer for %s field `%s`", MODtoChars(v.type.mod), v.toChars());
                                else if (v.storage_class & STC.nodefaultctor)
                                    error(funcdecl.loc, "field `%s` must be initialized in constructor", v.toChars());
                                else if (v.type.needsNested())
                                    error(funcdecl.loc, "field `%s` must be initialized in constructor, because it is nested struct", v.toChars());
                            }
                            else
                            {
                                bool mustInit = (v.storage_class & STC.nodefaultctor || v.type.needsNested());
                                if (mustInit && !(sc2.ctorflow.fieldinit[i].csx & CSX.this_ctor))
                                {
                                    funcdecl.error("field `%s` must be initialized but skipped", v.toChars());
                                }
                            }
                        }
                    }
                    sc2.ctorflow.freeFieldinit();

                    if (cd && !(sc2.ctorflow.callSuper & CSX.any_ctor) && cd.baseClass && cd.baseClass.ctor)
                    {
                        sc2.ctorflow.callSuper = CSX.none;

                        // Insert implicit super() at start of fbody
                        FuncDeclaration fd = resolveFuncCall(Loc.initial, sc2, cd.baseClass.ctor, null, funcdecl.vthis.type, null, 1);
                        if (!fd)
                        {
                            funcdecl.error("no match for implicit `super()` call in constructor");
                        }
                        else if (fd.storage_class & STC.disable)
                        {
                            funcdecl.error("cannot call `super()` implicitly because it is annotated with `@disable`");
                        }
                        else
                        {
                            Expression e1 = new SuperExp(Loc.initial);
                            Expression e = new CallExp(Loc.initial, e1);
                            e = e.expressionSemantic(sc2);
                            Statement s = new ExpStatement(Loc.initial, e);
                            funcdecl.fbody = new CompoundStatement(Loc.initial, s, funcdecl.fbody);
                        }
                    }
                    //printf("ctorflow.callSuper = x%x\n", sc2.ctorflow.callSuper);
                }

                /* https://issues.dlang.org/show_bug.cgi?id=17502
                 * Wait until after the return type has been inferred before
                 * generating the contracts for this function, and merging contracts
                 * from overrides.
                 *
                 * https://issues.dlang.org/show_bug.cgi?id=17893
                 * However should take care to generate this before inferered
                 * function attributes are applied, such as 'nothrow'.
                 *
                 * This was originally at the end of the first semantic pass, but
                 * required a fix-up to be done here for the '__result' variable
                 * type of __ensure() inside auto functions, but this didn't work
                 * if the out parameter was implicit.
                 */
                funcdecl.buildEnsureRequire();

                // Check for errors related to 'nothrow'.
                const blockexit = funcdecl.fbody.blockExit(funcdecl, f.isnothrow);
                if (f.isnothrow && blockexit & BE.throw_)
                    error(funcdecl.loc, "`nothrow` %s `%s` may throw", funcdecl.kind(), funcdecl.toPrettyChars());

                if (!(blockexit & (BE.throw_ | BE.halt) || funcdecl.flags & FUNCFLAG.hasCatches))
                {
                    /* Disable optimization on Win32 due to
                     * https://issues.dlang.org/show_bug.cgi?id=17997
                     */
//                    if (!global.params.isWindows || global.params.is64bit)
                        funcdecl.eh_none = true;         // don't generate unwind tables for this function
                }

                if (funcdecl.flags & FUNCFLAG.nothrowInprocess)
                {
                    if (funcdecl.type == f)
                        f = cast(TypeFunction)f.copy();
                    f.isnothrow = !(blockexit & BE.throw_);
                }

                if (funcdecl.fbody.isErrorStatement())
                {
                }
                else if (ad2 && funcdecl.isCtorDeclaration())
                {
                    /* Append:
                     *  return this;
                     * to function body
                     */
                    if (blockexit & BE.fallthru)
                    {
                        Statement s = new ReturnStatement(funcdecl.loc, null);
                        s = s.statementSemantic(sc2);
                        funcdecl.fbody = new CompoundStatement(funcdecl.loc, funcdecl.fbody, s);
                        funcdecl.hasReturnExp |= (funcdecl.hasReturnExp & 1 ? 16 : 1);
                    }
                }
                else if (funcdecl.fes)
                {
                    // For foreach(){} body, append a return 0;
                    if (blockexit & BE.fallthru)
                    {
                        Expression e = new IntegerExp(0);
                        Statement s = new ReturnStatement(Loc.initial, e);
                        funcdecl.fbody = new CompoundStatement(Loc.initial, funcdecl.fbody, s);
                        funcdecl.hasReturnExp |= (funcdecl.hasReturnExp & 1 ? 16 : 1);
                    }
                    assert(!funcdecl.returnLabel);
                }
                else
                {
                    const(bool) inlineAsm = (funcdecl.hasReturnExp & 8) != 0;
                    if ((blockexit & BE.fallthru) && f.next.ty != Tvoid && !inlineAsm)
                    {
                        Expression e;
                        if (!funcdecl.hasReturnExp)
                            funcdecl.error("has no `return` statement, but is expected to return a value of type `%s`", f.next.toChars());
                        else
                            funcdecl.error("no `return exp;` or `assert(0);` at end of function");
                        if (global.params.useAssert == CHECKENABLE.on && !global.params.useInline)
                        {
                            /* Add an assert(0, msg); where the missing return
                             * should be.
                             */
                            e = new AssertExp(funcdecl.endloc, new IntegerExp(0), new StringExp(funcdecl.loc, cast(char*)"missing return expression"));
                        }
                        else
                            e = new HaltExp(funcdecl.endloc);
                        e = new CommaExp(Loc.initial, e, f.next.defaultInit(Loc.initial));
                        e = e.expressionSemantic(sc2);
                        Statement s = new ExpStatement(Loc.initial, e);
                        funcdecl.fbody = new CompoundStatement(Loc.initial, funcdecl.fbody, s);
                    }
                }

                if (funcdecl.returns)
                {
                    bool implicit0 = addReturn0();
                    Type tret = implicit0 ? Type.tint32 : f.next;
                    assert(tret.ty != Tvoid);
                    if (funcdecl.vresult || funcdecl.returnLabel)
                        funcdecl.buildResultVar(scout ? scout : sc2, tret);

                    /* Cannot move this loop into NrvoWalker, because
                     * returns[i] may be in the nested delegate for foreach-body.
                     */
                    for (size_t i = 0; i < funcdecl.returns.dim; i++)
                    {
                        ReturnStatement rs = (*funcdecl.returns)[i];
                        Expression exp = rs.exp;
                        if (exp.op == TOK.error)
                            continue;
                        if (tret.ty == Terror)
                        {
                            // https://issues.dlang.org/show_bug.cgi?id=13702
                            exp = checkGC(sc2, exp);
                            continue;
                        }

                        if (!exp.implicitConvTo(tret) && funcdecl.isTypeIsolated(exp.type))
                        {
                            if (exp.type.immutableOf().implicitConvTo(tret))
                                exp = exp.castTo(sc2, exp.type.immutableOf());
                            else if (exp.type.wildOf().implicitConvTo(tret))
                                exp = exp.castTo(sc2, exp.type.wildOf());
                        }
                        exp = exp.implicitCastTo(sc2, tret);

                        if (f.isref)
                        {
                            // Function returns a reference
                            exp = exp.toLvalue(sc2, exp);
                            checkReturnEscapeRef(sc2, exp, false);
                        }
                        else
                        {
                            exp = exp.optimize(WANTvalue);

                            /* https://issues.dlang.org/show_bug.cgi?id=10789
                             * If NRVO is not possible, all returned lvalues should call their postblits.
                             */
                            if (!funcdecl.nrvo_can)
                                exp = doCopyOrMove(sc2, exp);

                            if (tret.hasPointers())
                                checkReturnEscape(sc2, exp, false);
                        }

                        exp = checkGC(sc2, exp);

                        if (funcdecl.vresult)
                        {
                            // Create: return vresult = exp;
                            exp = new BlitExp(rs.loc, funcdecl.vresult, exp);
                            exp.type = funcdecl.vresult.type;

                            if (rs.caseDim)
                                exp = Expression.combine(exp, new IntegerExp(rs.caseDim));
                        }
                        else if (funcdecl.tintro && !tret.equals(funcdecl.tintro.nextOf()))
                        {
                            exp = exp.implicitCastTo(sc2, funcdecl.tintro.nextOf());
                        }
                        rs.exp = exp;
                    }
                }
                if (funcdecl.nrvo_var || funcdecl.returnLabel)
                {
                    scope NrvoWalker nw = new NrvoWalker();
                    nw.fd = funcdecl;
                    nw.sc = sc2;
                    nw.visitStmt(funcdecl.fbody);
                }

                sc2 = sc2.pop();
            }

            funcdecl.frequire = funcdecl.mergeFrequire(funcdecl.frequire);
            funcdecl.fensure = funcdecl.mergeFensure(funcdecl.fensure, Id.result);

            Statement freq = funcdecl.frequire;
            Statement fens = funcdecl.fensure;

            /* Do the semantic analysis on the [in] preconditions and
             * [out] postconditions.
             */
            if (freq)
            {
                /* frequire is composed of the [in] contracts
                 */
                auto sym = new ScopeDsymbol();
                sym.parent = sc2.scopesym;
                sym.loc = funcdecl.loc;
                sym.endlinnum = funcdecl.endloc.linnum;
                sc2 = sc2.push(sym);
                sc2.flags = (sc2.flags & ~SCOPE.contract) | SCOPE.require;

                // BUG: need to error if accessing out parameters
                // BUG: need to disallow returns and throws
                // BUG: verify that all in and ref parameters are read
                freq = freq.statementSemantic(sc2);
                freq.blockExit(funcdecl, false);

                funcdecl.eh_none = false;

                sc2 = sc2.pop();

                if (!global.params.useIn)
                    freq = null;
            }
            if (fens)
            {
                /* fensure is composed of the [out] contracts
                 */
                if (f.next.ty == Tvoid && funcdecl.fensures)
                {
                    foreach (e; *funcdecl.fensures)
                    {
                        if (e.id)
                        {
                            funcdecl.error(e.ensure.loc, "`void` functions have no result");
                            //fens = null;
                        }
                    }
                }

                sc2 = scout; //push
                sc2.flags = (sc2.flags & ~SCOPE.contract) | SCOPE.ensure;

                // BUG: need to disallow returns and throws

                if (funcdecl.fensure && f.next.ty != Tvoid)
                    funcdecl.buildResultVar(scout, f.next);

                fens = fens.statementSemantic(sc2);
                fens.blockExit(funcdecl, false);

                funcdecl.eh_none = false;

                sc2 = sc2.pop();

                if (!global.params.useOut)
                    fens = null;
            }
            if (funcdecl.fbody && funcdecl.fbody.isErrorStatement())
            {
            }
            else
            {
                auto a = new Statements();
                // Merge in initialization of 'out' parameters
                if (funcdecl.parameters)
                {
                    for (size_t i = 0; i < funcdecl.parameters.dim; i++)
                    {
                        VarDeclaration v = (*funcdecl.parameters)[i];
                        if (v.storage_class & STC.out_)
                        {
                            if (!v._init)
                            {
                                v.error("Zero-length `out` parameters are not allowed.");
                                return;
                            }
                            ExpInitializer ie = v._init.isExpInitializer();
                            assert(ie);
                            if (ie.exp.op == TOK.construct)
                                ie.exp.op = TOK.assign; // construction occurred in parameter processing
                            a.push(new ExpStatement(Loc.initial, ie.exp));
                        }
                    }
                }

                if (_arguments)
                {
                    /* Advance to elements[] member of TypeInfo_Tuple with:
                     *  _arguments = v_arguments.elements;
                     */
                    Expression e = new VarExp(Loc.initial, funcdecl.v_arguments);
                    e = new DotIdExp(Loc.initial, e, Id.elements);
                    e = new ConstructExp(Loc.initial, _arguments, e);
                    e = e.expressionSemantic(sc2);

                    _arguments._init = new ExpInitializer(Loc.initial, e);
                    auto de = new DeclarationExp(Loc.initial, _arguments);
                    a.push(new ExpStatement(Loc.initial, de));
                }

                // Merge contracts together with body into one compound statement

                if (freq || fpreinv)
                {
                    if (!freq)
                        freq = fpreinv;
                    else if (fpreinv)
                        freq = new CompoundStatement(Loc.initial, freq, fpreinv);

                    a.push(freq);
                }

                if (funcdecl.fbody)
                    a.push(funcdecl.fbody);

                if (fens || fpostinv)
                {
                    if (!fens)
                        fens = fpostinv;
                    else if (fpostinv)
                        fens = new CompoundStatement(Loc.initial, fpostinv, fens);

                    auto ls = new LabelStatement(Loc.initial, Id.returnLabel, fens);
                    funcdecl.returnLabel.statement = ls;
                    a.push(funcdecl.returnLabel.statement);

                    if (f.next.ty != Tvoid && funcdecl.vresult)
                    {
                        // Create: return vresult;
                        Expression e = new VarExp(Loc.initial, funcdecl.vresult);
                        if (funcdecl.tintro)
                        {
                            e = e.implicitCastTo(sc, funcdecl.tintro.nextOf());
                            e = e.expressionSemantic(sc);
                        }
                        auto s = new ReturnStatement(Loc.initial, e);
                        a.push(s);
                    }
                }
                if (addReturn0())
                {
                    // Add a return 0; statement
                    Statement s = new ReturnStatement(Loc.initial, new IntegerExp(0));
                    a.push(s);
                }

                Statement sbody = new CompoundStatement(Loc.initial, a);

                /* Append destructor calls for parameters as finally blocks.
                 */
                if (funcdecl.parameters)
                {
                    foreach (v; *funcdecl.parameters)
                    {
                        if (v.storage_class & (STC.ref_ | STC.out_ | STC.lazy_))
                            continue;
                        if (v.needsScopeDtor())
                        {
                            // same with ExpStatement.scopeCode()
                            Statement s = new DtorExpStatement(Loc.initial, v.edtor, v);
                            v.storage_class |= STC.nodtor;

                            s = s.statementSemantic(sc2);

                            bool isnothrow = f.isnothrow & !(funcdecl.flags & FUNCFLAG.nothrowInprocess);
                            const blockexit = s.blockExit(funcdecl, isnothrow);
                            if (blockexit & BE.throw_)
                                funcdecl.eh_none = false;
                            if (f.isnothrow && isnothrow && blockexit & BE.throw_)
                                error(funcdecl.loc, "`nothrow` %s `%s` may throw", funcdecl.kind(), funcdecl.toPrettyChars());
                            if (funcdecl.flags & FUNCFLAG.nothrowInprocess && blockexit & BE.throw_)
                                f.isnothrow = false;

                            if (sbody.blockExit(funcdecl, f.isnothrow) == BE.fallthru)
                                sbody = new CompoundStatement(Loc.initial, sbody, s);
                            else
                                sbody = new TryFinallyStatement(Loc.initial, sbody, s);
                        }
                    }
                }
                // from this point on all possible 'throwers' are checked
                funcdecl.flags &= ~FUNCFLAG.nothrowInprocess;

                if (funcdecl.isSynchronized())
                {
                    /* Wrap the entire function body in a synchronized statement
                     */
                    ClassDeclaration cd = funcdecl.isThis() ? funcdecl.isThis().isClassDeclaration() : funcdecl.parent.isClassDeclaration();
                    if (cd)
                    {
                        if (!global.params.is64bit && global.params.isWindows && !funcdecl.isStatic() && !sbody.usesEH() && !global.params.trace)
                        {
                            /* The back end uses the "jmonitor" hack for syncing;
                             * no need to do the sync at this level.
                             */
                        }
                        else
                        {
                            Expression vsync;
                            if (funcdecl.isStatic())
                            {
                                // The monitor is in the ClassInfo
                                vsync = new DotIdExp(funcdecl.loc, symbolToExp(cd, funcdecl.loc, sc2, false), Id.classinfo);
                            }
                            else
                            {
                                // 'this' is the monitor
                                vsync = new VarExp(funcdecl.loc, funcdecl.vthis);
                            }
                            sbody = new PeelStatement(sbody); // don't redo semantic()
                            sbody = new SynchronizedStatement(funcdecl.loc, vsync, sbody);
                            sbody = sbody.statementSemantic(sc2);
                        }
                    }
                    else
                    {
                        funcdecl.error("synchronized function `%s` must be a member of a class", funcdecl.toChars());
                    }
                }

                // If declaration has no body, don't set sbody to prevent incorrect codegen.
                if (funcdecl.fbody || funcdecl.allowsContractWithoutBody())
                    funcdecl.fbody = sbody;
            }

            // Fix up forward-referenced gotos
            if (funcdecl.gotos)
            {
                for (size_t i = 0; i < funcdecl.gotos.dim; ++i)
                {
                    (*funcdecl.gotos)[i].checkLabel();
                }
            }

            if (funcdecl.naked && (funcdecl.fensures || funcdecl.frequires))
                funcdecl.error("naked assembly functions with contracts are not supported");

            sc2.ctorflow.callSuper = CSX.none;
            sc2.pop();
        }

        if (funcdecl.checkClosure())
        {
            // We should be setting errors here instead of relying on the global error count.
            //errors = true;
        }

        /* If function survived being marked as impure, then it is pure
         */
        if (funcdecl.flags & FUNCFLAG.purityInprocess)
        {
            funcdecl.flags &= ~FUNCFLAG.purityInprocess;
            if (funcdecl.type == f)
                f = cast(TypeFunction)f.copy();
            f.purity = PURE.fwdref;
        }

        if (funcdecl.flags & FUNCFLAG.safetyInprocess)
        {
            funcdecl.flags &= ~FUNCFLAG.safetyInprocess;
            if (funcdecl.type == f)
                f = cast(TypeFunction)f.copy();
            f.trust = TRUST.safe;
        }

        if (funcdecl.flags & FUNCFLAG.nogcInprocess)
        {
            funcdecl.flags &= ~FUNCFLAG.nogcInprocess;
            if (funcdecl.type == f)
                f = cast(TypeFunction)f.copy();
            f.isnogc = true;
        }

        if (funcdecl.flags & FUNCFLAG.returnInprocess)
        {
            funcdecl.flags &= ~FUNCFLAG.returnInprocess;
            if (funcdecl.storage_class & STC.return_)
            {
                if (funcdecl.type == f)
                    f = cast(TypeFunction)f.copy();
                f.isreturn = true;
            }
        }

        funcdecl.flags &= ~FUNCFLAG.inferScope;

        // Eliminate maybescope's
        {
            // Create and fill array[] with maybe candidates from the `this` and the parameters
            VarDeclaration[] array = void;

            VarDeclaration[10] tmp = void;
            size_t dim = (funcdecl.vthis !is null) + (funcdecl.parameters ? funcdecl.parameters.dim : 0);
            if (dim <= tmp.length)
                array = tmp[0 .. dim];
            else
            {
                auto ptr = cast(VarDeclaration*)mem.xmalloc(dim * VarDeclaration.sizeof);
                array = ptr[0 .. dim];
            }
            size_t n = 0;
            if (funcdecl.vthis)
                array[n++] = funcdecl.vthis;
            if (funcdecl.parameters)
            {
                foreach (v; *funcdecl.parameters)
                {
                    array[n++] = v;
                }
            }

            eliminateMaybeScopes(array[0 .. n]);

            if (dim > tmp.length)
                mem.xfree(array.ptr);
        }

        // Infer STC.scope_
        if (funcdecl.parameters && !funcdecl.errors)
        {
            size_t nfparams = f.parameterList.length;
            assert(nfparams == funcdecl.parameters.dim);
            foreach (u, v; *funcdecl.parameters)
            {
                if (v.storage_class & STC.maybescope)
                {
                    //printf("Inferring scope for %s\n", v.toChars());
                    Parameter p = f.parameterList[u];
                    notMaybeScope(v);
                    v.storage_class |= STC.scope_ | STC.scopeinferred;
                    p.storageClass |= STC.scope_ | STC.scopeinferred;
                    assert(!(p.storageClass & STC.maybescope));
                }
            }
        }

        if (funcdecl.vthis && funcdecl.vthis.storage_class & STC.maybescope)
        {
            notMaybeScope(funcdecl.vthis);
            funcdecl.vthis.storage_class |= STC.scope_ | STC.scopeinferred;
            f.isscope = true;
            f.isscopeinferred = true;
        }

        // reset deco to apply inference result to mangled name
        if (f != funcdecl.type)
            f.deco = null;

        // Do semantic type AFTER pure/nothrow inference.
        if (!f.deco && funcdecl.ident != Id.xopEquals && funcdecl.ident != Id.xopCmp)
        {
            sc = sc.push();
            if (funcdecl.isCtorDeclaration()) // https://issues.dlang.org/show_bug.cgi?id=#15665
                sc.flags |= SCOPE.ctor;
            sc.stc = 0;
            sc.linkage = funcdecl.linkage; // https://issues.dlang.org/show_bug.cgi?id=8496
            funcdecl.type = f.typeSemantic(funcdecl.loc, sc);
            sc = sc.pop();
        }

        /* If this function had instantiated with gagging, error reproduction will be
         * done by TemplateInstance::semantic.
         * Otherwise, error gagging should be temporarily ungagged by functionSemantic3.
         */
        funcdecl.semanticRun = PASS.semantic3done;
        funcdecl.semantic3Errors = (global.errors != oldErrors) || (funcdecl.fbody && funcdecl.fbody.isErrorStatement());
        if (funcdecl.type.ty == Terror)
            funcdecl.errors = true;
        //printf("-FuncDeclaration::semantic3('%s.%s', sc = %p, loc = %s)\n", parent.toChars(), toChars(), sc, loc.toChars());
        //fflush(stdout);
    }

    override void visit(CtorDeclaration ctor)
    {
        //printf("CtorDeclaration()\n%s\n", ctor.fbody.toChars());
        if (ctor.semanticRun >= PASS.semantic3)
            return;

        /* If any of the fields of the aggregate have a destructor, add
         *   scope (failure) { this.fieldDtor(); }
         * as the first statement. It is not necessary to add it after
         * each initialization of a field, because destruction of .init constructed
         * structs should be benign.
         * https://issues.dlang.org/show_bug.cgi?id=14246
         */
        AggregateDeclaration ad = ctor.toParent2().isAggregateDeclaration();
        if (ad && ad.fieldDtor && global.params.dtorFields)
        {
            /* Generate:
             *   this.fieldDtor()
             */
            Expression e = new ThisExp(ctor.loc);
            e.type = ad.type.mutableOf();
            e = new DotVarExp(ctor.loc, e, ad.fieldDtor, false);
            e = new CallExp(ctor.loc, e);
            auto sexp = new ExpStatement(ctor.loc, e);
            auto ss = new ScopeStatement(ctor.loc, sexp, ctor.loc);

            version (all)
            {
                /* Generate:
                 *   try { ctor.fbody; }
                 *   catch (Exception __o)
                 *   { this.fieldDtor(); throw __o; }
                 * This differs from the alternate scope(failure) version in that an Exception
                 * is caught rather than a Throwable. This enables the optimization whereby
                 * the try-catch can be removed if ctor.fbody is nothrow. (nothrow only
                 * applies to Exception.)
                 */
                Identifier id = Identifier.generateId("__o");
                auto ts = new ThrowStatement(ctor.loc, new IdentifierExp(ctor.loc, id));
                auto handler = new CompoundStatement(ctor.loc, ss, ts);

                auto catches = new Catches();
                auto ctch = new Catch(ctor.loc, getException(), id, handler);
                catches.push(ctch);

                ctor.fbody = new TryCatchStatement(ctor.loc, ctor.fbody, catches);
            }
            else
            {
                /* Generate:
                 *   scope (failure) { this.fieldDtor(); }
                 * Hopefully we can use this version someday when scope(failure) catches
                 * Exception instead of Throwable.
                 */
                auto s = new OnScopeStatement(ctor.loc, TOK.onScopeFailure, ss);
                ctor.fbody = new CompoundStatement(ctor.loc, s, ctor.fbody);
            }
        }
        visit(cast(FuncDeclaration)ctor);
    }


    override void visit(Nspace ns)
    {
        if (ns.semanticRun >= PASS.semantic3)
            return;
        ns.semanticRun = PASS.semantic3;
        static if (LOG)
        {
            printf("Nspace::semantic3('%s')\n", ns.toChars());
        }
        if (ns.members)
        {
            sc = sc.push(ns);
            sc.linkage = LINK.cpp;
            foreach (s; *ns.members)
            {
                s.semantic3(sc);
            }
            sc.pop();
        }
    }

    override void visit(AttribDeclaration ad)
    {
        Dsymbols* d = ad.include(sc);
        if (d)
        {
            Scope* sc2 = ad.newScope(sc);
            for (size_t i = 0; i < d.dim; i++)
            {
                Dsymbol s = (*d)[i];
                s.semantic3(sc2);
            }
            if (sc2 != sc)
                sc2.pop();
        }
    }

    override void visit(AggregateDeclaration ad)
    {
        //printf("AggregateDeclaration::semantic3(sc=%p, %s) type = %s, errors = %d\n", sc, toChars(), type.toChars(), errors);
        if (!ad.members)
            return;

        StructDeclaration sd = ad.isStructDeclaration();
        if (!sc) // from runDeferredSemantic3 for TypeInfo generation
        {
            assert(sd);
            sd.semanticTypeInfoMembers();
            return;
        }

        auto sc2 = ad.newScope(sc);

        for (size_t i = 0; i < ad.members.dim; i++)
        {
            Dsymbol s = (*ad.members)[i];
            s.semantic3(sc2);
        }

        sc2.pop();

        // don't do it for unused deprecated types
        // or error ypes
        if (!ad.getRTInfo && Type.rtinfo && (!ad.isDeprecated() || global.params.useDeprecated != Diagnostic.error) && (ad.type && ad.type.ty != Terror))
        {
            // Evaluate: RTinfo!type
            auto tiargs = new Objects();
            tiargs.push(ad.type);
            auto ti = new TemplateInstance(ad.loc, Type.rtinfo, tiargs);

            Scope* sc3 = ti.tempdecl._scope.startCTFE();
            sc3.tinst = sc.tinst;
            sc3.minst = sc.minst;
            if (ad.isDeprecated())
                sc3.stc |= STC.deprecated_;

            ti.dsymbolSemantic(sc3);
            ti.semantic2(sc3);
            ti.semantic3(sc3);
            auto e = symbolToExp(ti.toAlias(), Loc.initial, sc3, false);

            sc3.endCTFE();

            e = e.ctfeInterpret();
            ad.getRTInfo = e;
        }
        if (sd)
            sd.semanticTypeInfoMembers();
        ad.semanticRun = PASS.semantic3done;
    }
}

private struct FuncDeclSem3
{
    // The FuncDeclaration subject to Semantic analysis
    FuncDeclaration funcdecl;

    // Scope of analysis
    Scope* sc;
    this(FuncDeclaration fd,Scope* s)
    {
        funcdecl = fd;
        sc = s;
    }

    /* Checks that the overriden functions (if any) have in contracts if
     * funcdecl has an in contract.
     */
    void checkInContractOverrides()
    {
        if (funcdecl.frequires)
        {
            for (size_t i = 0; i < funcdecl.foverrides.dim; i++)
            {
                FuncDeclaration fdv = funcdecl.foverrides[i];
                if (fdv.fbody && !fdv.frequires)
                {
                    funcdecl.error("cannot have an in contract when overridden function `%s` does not have an in contract", fdv.toPrettyChars());
                    break;
                }
            }
        }
    }
}
