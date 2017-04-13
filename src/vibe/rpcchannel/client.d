module vibe.rpcchannel.client;

import std.traits;
import std.range : ElementType;
import std.exception : enforceEx, collectException;

import tinyevent;
import vibe.core.sync;
import vibe.core.stream;
import vibe.core.core;

import vibe.rpcchannel.base;
import vibe.rpcchannel.protocol;

import std.stdio;

/**
 *
 */
RPCClient!(API, ConnectionInfo) createClientSession(API, ConnectionInfo)(Stream stream, ConnectionInfo info)
{
    auto client = new RPCClient!(API, ConnectionInfo)(stream, info);
    return client;
}

string generateMethods(API)()
{
    import std.conv : to;
    string result;

    foreach (member; __traits(derivedMembers, API))
    {
        // Guards against private members
        static if(__traits(compiles, __traits(getMember, API, member)))
        {
            static if(isSomeFunction!(__traits(getMember, API, member))
                && !hasUDA!(__traits(getMember, API, member), IgnoreUDA)
                && !isSpecialFunction!member)
            {
                alias overloads = MemberFunctionsTuple!(API, member);

                foreach(MethodType; overloads)
                {
                    alias TParams = Parameters!MethodType;
                    alias TRet = ReturnType!MethodType;
                    enum mangle = typeof(MethodType).mangleof;

                    string code = "override " ~ TRet.stringof ~ " " ~ member ~ "(";
                    foreach(i, param; TParams)
                    {
                        if(i != 0)
                            code ~= ", ";
                        code ~= param.stringof ~ " t" ~ to!string(i);
                    }
                    code ~= ")\n{\n";
                    string call = "callMethod!(" ~ TRet.stringof ~ " function" ~ TParams.stringof ~ ")(\"" ~ member ~ "\", \"" ~ mangle ~ "\"";
                    foreach(i, param; TParams)
                    {
                        call ~= ", t" ~ to!string(i);
                    }
                    call ~= ");";
                    static if (is(TRet == void))
                        code ~= "    " ~ call;
                    else
                        code ~= "    return " ~ call;
                    code ~= "\n}\n\n";

                    result ~= code;
                }
            }
        }
    }

    return result;
}

// Just make sure all code paths are covered The compiler
// does actually a much better job checking the result when
// we mixin the code for some real tests in test.d ;-)
unittest
{
    static abstract class TestAPI
    {
        void foo();
        int bar(int a, int b);
        @ignoreRPC int baz();
    }

    auto result = generateMethods!TestAPI;
}

template modName(T)
{
    static if(__traits(compiles, moduleName!T))
        enum modName = moduleName!T;
    else
        enum modName = "";
}

string generateImports(API)()
{
    string result;
    int[string] modules;

    foreach (member; __traits(derivedMembers, API))
    {
        // Guards against private members
        static if(__traits(compiles, __traits(getMember, API, member)))
        {
            static if(isSomeFunction!(__traits(getMember, API, member))
                && !hasUDA!(__traits(getMember, API, member), IgnoreUDA)
                && !isSpecialFunction!member)
            {
                alias overloads = MemberFunctionsTuple!(API, member);

                foreach(MethodType; overloads)
                {
                    alias TParams = Parameters!MethodType;
                    alias TRet = ReturnType!MethodType;
                    modules[modName!TRet] = 1;

                    foreach(Param; TParams)
                        modules[modName!Param] = 1;
                }
            }
        }
    }

    foreach(mod; modules.keys)
    {
        if (mod.length)
            result ~= "import " ~ mod ~ ";\n";
    }

    return result;
}

// Just make sure all code paths are covered. The compiler
// does actually a much better job checking the result when
// we mixin the code for some real tests in test.d ;-)
unittest
{
    struct S {}
    static abstract class TestAPI
    {
        S foo();
        int bar(S a, int b);
        @ignoreRPC int baz();
    }

    auto result = generateImports!TestAPI;
}

private struct RPCRequest
{
private:
    // Signaled once a new response is ready
    ManualEvent _readyEvent;

public:
    // If should throw an Exception
    bool exception = false;
    // Type of following response
    ResponseType type;

    void initialize()
    {
        _readyEvent = createManualEvent();
    }

    void emitReady()
    {
        _readyEvent.emit();
    }

    void waitReady()
    {
        _readyEvent.wait();
    }
}

class RPCClient(API, ConnectionInfo) : API
{
private:
    Stream _stream;
    // Used to protect concurrent calls to callMethod
    TaskMutex _writeMutex;
    // Used to protect concurrent calls to callMethod
    TaskMutex _requestMutex;

    // Counter of message ids
    uint _idCounter = 0;

    // The task reading from the stream and dispatching events
    Task _readTask;
    // Signalled when a call result or event is done processing
    ManualEvent _readDone;
    // Whether we are processing a event or call result. Avoid interleaving
    bool _processingRead = false;

    // The pending call request
    RPCRequest _pending;

    void startRead()
    {
        _processingRead = true;
    }

    void finishRead()
    {
        _processingRead = false;
        _readDone.emit();
    }

    /*
     * We were somehow disconnected. Clean up all tasks and notify waiting
     * calls by throwing Exceptions.
     */
    void shutdown () nothrow
    {
        _pending.exception = true;
        collectException(_pending.emitReady());

        if (_stream)
        {
            _stream = null;
            collectException(onDisconnect.emit(this));
        }

        if(Task.getThis != _readTask)
            collectException(_readTask.interrupt());
    }

    /*
     *
     */
    ReturnType!MethodType callMethod(MethodType)(string name, string mangle, Parameters!MethodType args)
    {
        assert(Task.getThis != _readTask, "Can not call remote methods from event handler task");
        // Make sure there can't be multiple pending calls
        synchronized(_requestMutex)
        {
            scope(exit)
                finishRead();
            enforceEx!DisconnectedException(connected);


            alias TParams = Parameters!MethodType;
            alias TRet = ReturnType!MethodType;
            auto msgID = _idCounter++;

            // TODO: Do we have to handle disconnected exceptions?
            // Send request
            synchronized(_writeMutex)
            {
                _stream.serializeToJsonLine(RequestType.call);
                auto msg = CallMessage(msgID, name, mangle, TParams.length);
                _stream.serializeToJsonLine(msg);
                foreach(arg; args)
                    _stream.serializeToJsonLine(arg);
                _stream.flush();
            }

            // Wait for response
            _pending.waitReady();

            // If we were interrupted, disconnected, ...
            if (_pending.exception)
                throw new DisconnectedException();

            switch(_pending.type)
            {
                case ResponseType.error:
                    ErrorMessage info;
                    try
                        info = _stream.deserializeJsonLine!ErrorMessage();
                    catch(Exception e)
                    {
                        shutdown();
                        throw e;
                    }
                    throw new RPCException(/*info.type, */info.message, info.file, info.line);
                case ResponseType.result:
                    ResultMessage info;
                    try
                        info = _stream.deserializeJsonLine!ResultMessage();
                    catch(Exception e)
                    {
                        shutdown();
                        throw e;
                    }

                    // Exceptions here caused by deserialization failure of the result are recoverable
                    static if(is(TRet == void))
                    {
                        // Discard result
                        if (info.hasResult)
                            _stream.deserializeJsonLine!void();
                        break;
                    }
                    else
                    {
                        return _stream.deserializeJsonLine!TRet();
                    }
                default:
                    assert(false);
            }
        }
    }

    void emitEvent(string name)(EventMessage event)
    {
        alias EventType = ElementType!(typeof(__traits(getMember, typeof(this), name)));
        alias TRet = ReturnType!EventType;
        alias TArgs = Parameters!EventType;
        assert(event.parameters == TArgs.length);
        TArgs args;

        size_t parametersRead = 0;
        try
        {
            foreach(i, Arg; TArgs)
            {
                parametersRead++;
                args[i] = _stream.deserializeJsonLine!Arg();
            }
            mixin(`this.` ~ name ~ `.emit(args);`);
        }
        catch (Exception e)
        {
            _stream.skipParameters(event.parameters - parametersRead);
        }
    }

    void handleEventMessage()
    {
        scope(exit)
            finishRead();

        auto event = _stream.deserializeJsonLine!EventMessage();

        foreach (member; __traits(derivedMembers, API))
        {
            // Guards against private members
            static if(__traits(compiles, __traits(getMember, API, member)))
            {
                static if(isEmittable2!(typeof(__traits(getMember, API, member))) &&
                     !hasUDA!(__traits(getMember, API, member), IgnoreUDA))
                {
                    alias EventType = ElementType!(typeof(__traits(getMember, API, member)));
                    alias TRet = ReturnType!EventType;
                    alias TArgs = Parameters!EventType;

                    if (event.target == member && event.parameters ==
                        Parameters!(EventType).length)
                    {
                        emitEvent!member(event);
                        return;
                    }
                }
            }
        }

        // Ignore unhandled events
        _stream.skipParameters(event.parameters);
    }

    void readTaskMain()
    {
        try
        {
            while(true)
            {
                // If another task is busy processing a message
                if (_processingRead)
                    _readDone.wait();

                // Start processing a message
                startRead();

                const type = _stream.deserializeJsonLine!ResponseType();
                switch(type)
                {
                    case ResponseType.disconnect:
                        shutdown();
                        return;
                    case ResponseType.error:
                        goto case;
                    case ResponseType.result:
                        _pending.type = type;
                        _pending.emitReady();
                        break;
                    case ResponseType.event:
                        handleEventMessage();
                        break;
                    default:
                        throw new Exception("Invalid response type");
                }
            }
        }
        catch (InterruptException)
        {
            // OK, terminate
        }
        catch(Exception e)
        {
            shutdown();
        }
    }

    this(Stream stream, ConnectionInfo info)
    {
        connectionInfo = info;
        _stream = stream;
        _writeMutex = new TaskMutex();
        _requestMutex = new TaskMutex();
        _readDone = createManualEvent();

        _pending.initialize();
        _readTask = runTask(&readTaskMain);
    }

public:
    mixin(generateImports!API);
    mixin(generateMethods!API);

    /**
     * Connection info passed in to createClientSession.
     */
    ConnectionInfo connectionInfo;

    /**
     * Whether client session is still connected.
     * Note: This does not necessarily mean the underlying stream is closed.
     */
    @property bool connected()
    {
        return _stream !is null;
    }

    /**
     * Called when disconnected
     */
    Event!(RPCClient!(API, ConnectionInfo)) onDisconnect;

    /**
     * Sends disconnect signal to remote server and stops internal tasks.
     * 
     * Note: Do not call any functions on this client instance after disconnecting.
     * This does not close the underlying stream. Recommended usage patterns:
     * -----------------------------
     * client.disconnect();
     * client.connectionInfo.close();
     * destroy(client);
     * -----------------------------
     */
    void disconnect()
    {
        if (!connected)
            return;

        synchronized(_writeMutex)
        {
            _stream.serializeToJsonLine(RequestType.disconnect);
            _stream.flush();
            shutdown();
        }
    }
}
