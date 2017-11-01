/*
  Copyright: Martin Nowak 2013 -
  License: Subject to the terms of the MIT license, as written in the included LICENSE file.
  Authors: $(WEB code.dawg.eu, Martin Nowak)
*/
module drepl.interpreter;
import drepl.engines;
import std.algorithm, std.array, std.conv, std.string, std.typecons;

struct InterpreterResult
{
    enum State { success, error, incomplete };
    State state;
    string stdout, stderr;
}

shared static this()
{
    import core.memory : GC;
    import ddmd.astbase : ASTBase;
    import ddmd.globals : global;
    import ddmd.identifier : Id;

    Id.initialize();
    global._init();
    global.params.isLinux = true;
    global.params.is64bit = (size_t.sizeof == 8);
    global.params.useUnitTests = true;
    // global.params.showGaggedErrors = true;
    ASTBase.Type._init();
    // FIXME: need to disable GC or it'll collect some of dmd's AST,
    // e.g. stringtable entries
    GC.disable();
}

struct Interpreter(Engine) if (isEngine!Engine)
{
    alias IR = InterpreterResult;

    IR interpret(const(char)[] line)
    {
        // ignore empty lines without incomplete input
        if (!_incomplete.data.length && !line.length)
            return IR(IR.State.success);

        _incomplete.put(line);
        _incomplete.put('\n');
        auto input = _incomplete.data;

        // dismiss buffer after two consecutive empty lines
        if (input.endsWith("\n\n\n"))
        {
            _incomplete.clear();
            return IR(IR.State.error, "", "You typed two blank lines. Starting a new command.");
        }

        immutable kind = parse(input);
        import std.stdio;
        writeln("kind ", kind);
        EngineResult res;
        final switch (kind)
        {
        case Kind.Decl:
            ++modId;
            res = _engine.evalDecl(input);
            break;
        case Kind.Stmt:
            ++modId;
            res = _engine.evalStmt(input);
            break;
        case Kind.Expr:
            ++modId;
            res = _engine.evalExpr(input);
            break;

        case Kind.WhiteSpace:
            return IR(IR.State.success);

        case Kind.Incomplete:
            return IR(IR.State.incomplete);

        case Kind.Error:
            _incomplete.clear();
            return IR(IR.State.error, "", "Error parsing '"~input.strip.idup~"'.");
        }
        _incomplete.clear();
        return IR(res.success ? IR.State.success : IR.State.error, res.stdout, res.stderr);
    }

private:
    enum Kind { Decl, Stmt, Expr, WhiteSpace, Incomplete, Error, }

    Kind parse(scope const(char)[] input)
    {
        import core.exception : RangeError;
        import ddmd.id : Identifier;
        import ddmd.lexer : Lexer, TOKeof;
        import ddmd.globals : global;

        import std.stdio;
        scope (exit) global.errors = 0;
        input ~= '\0';

        auto fname = format!"_mod%d.d\0"(modId);
        auto mname = format!"_mod%d"(modId);

        enum doDocComment = true;
        enum doHdrGen = true;
        enum commentToken = true;

        scope lexer = new Lexer(fname.ptr, input.ptr, 0, input.length - 1, !doDocComment, !commentToken);
        auto tok = lexer.nextToken; // TODO: capture dmd errors
        if (global.errors)
            return Kind.Error;
        else if (tok == TOKeof)
            return Kind.WhiteSpace;

        if (!input.balancedParens('{', '}') ||
            !input.balancedParens('(', ')') ||
            !input.balancedParens('[', ']'))
            return Kind.Incomplete;

        auto id = Identifier.idPool(mname);
        auto mod = new ASTBase.Module(fname.ptr, id, !doDocComment, !doHdrGen);

        static foreach (kind; [Kind.Decl, Kind.Stmt, Kind.Expr])
        {
            try
            {
                if (parse!kind(mod, input))
                    return kind;
            }
            catch (RangeError e) // `struct Foo`
            {
                import std.stdio;
                writeln(e);
            }
        }
        return Kind.Error;
    }

    bool parse(Kind kind)(ASTBase.Module m, scope const(char)[] input)
    {
        import ddmd.parse : Parser, PSscope;
        import ddmd.globals : global;

        enum doDocComment = true;
        scope p = new Parser!ASTBase(m, input, !doDocComment);
        p.nextToken();
        auto olderrors = global.startGagging();
        static if (kind == Kind.Decl)
        {
            enum once = true;
            p.parseDeclDefs(once);
        }
        else static if (kind == Kind.Stmt)
            auto s = p.parseStatement(PSscope);
        else static if (kind == Kind.Expr)
            auto e = p.parseExpression();
        return !global.endGagging(olderrors);
    }

    unittest
    {
        auto intp = interpreter(echoEngine());
        assert(intp.parse("3+2") == Kind.Expr);
        // only single expressions
        assert(intp.parse("3+2 foo()") == Kind.Error);
        assert(intp.parse("3+2;") == Kind.Stmt);
        // multiple statements
        assert(intp.parse("3+2; foo();") == Kind.Stmt);
        assert(intp.parse("struct Foo {}") == Kind.Decl);
        // multiple declarations
        assert(intp.parse("void foo() {} void bar() {}") == Kind.Decl);
        // can't currently mix declarations and statements
        assert(intp.parse("void foo() {} foo();") == Kind.Error);
        // or declarations and expressions
        assert(intp.parse("void foo() {} foo()") == Kind.Error);
        // or statments and expressions
        assert(intp.parse("foo(); foo()") == Kind.Error);

        assert(intp.parse("import std.stdio;") == Kind.Decl);
    }

    import ddmd.astbase : ASTBase;

    Engine _engine;
    Appender!(char[]) _incomplete;
    size_t modId;
}

Interpreter!Engine interpreter(Engine)(auto ref Engine e) if (isEngine!Engine)
{
    return Interpreter!Engine(move(e));
}

unittest
{
    alias IR = InterpreterResult;
    auto intp = interpreter(echoEngine());
    assert(intp.interpret("3 * foo") == IR(IR.State.success, "3 * foo"));
    assert(intp.interpret("stmt!(T)();") == IR(IR.State.success, "stmt!(T)();"));
    assert(intp.interpret("auto a = 3 * foo;") == IR(IR.State.success, "auto a = 3 * foo;"));

    void testMultiline(string input)
    {
        import std.string : splitLines;
        auto lines = splitLines(input);
        foreach (line; lines[0 .. $-1])
            assert(intp.interpret(line) == IR(IR.State.incomplete, ""));
        assert(intp.interpret(lines[$-1]) == IR(IR.State.success, input));
    }

    testMultiline(
        q{void foo() {
            }});

    testMultiline(
        q{int foo() {
                auto bar(int v) { return v; }
                auto v = 3 * 12;
                return bar(v);
            }});

    testMultiline(
        q{struct Foo(T) {
                void bar() {
                }
            }});

    testMultiline(
        q{struct Foo(T) {
                void bar() {

                }
            }});
}

unittest
{
    alias IR = InterpreterResult;
    auto intp = interpreter(echoEngine());
    assert(intp.interpret("struct Foo {").state == IR.State.incomplete);
    assert(intp.interpret("").state == IR.State.incomplete);
    assert(intp.interpret("").state == IR.State.error);

    assert(intp.interpret("struct Foo {").state == IR.State.incomplete);
    assert(intp.interpret("").state == IR.State.incomplete);
    assert(intp.interpret("}").state == IR.State.success);
}

unittest
{
    alias IR = InterpreterResult;
    auto intp = interpreter(echoEngine());
    assert(intp.interpret("//comment").state == IR.State.success);
    assert(intp.interpret("//comment").state == IR.State.success);

    assert(intp.interpret("struct Foo {").state == IR.State.incomplete);
    assert(intp.interpret("//comment").state == IR.State.incomplete);
    assert(intp.interpret("//comment").state == IR.State.incomplete);
    assert(intp.interpret("").state == IR.State.incomplete);
    assert(intp.interpret("//comment").state == IR.State.incomplete);
    assert(intp.interpret("").state == IR.State.incomplete);
    assert(intp.interpret("").state == IR.State.error);
}
