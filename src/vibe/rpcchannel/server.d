module vibe.rpcchannel.server;

import std.traits;
import std.exception : enforceEx, collectException;
import std.range : ElementType;

import tinyevent;
import vibe.core.stream;
import vibe.core.sync;
import vibe.core.core;

import vibe.rpcchannel.base;
import vibe.rpcchannel.protocol;

/**
 * Whether a class can be used as an API server
 */
enum bool isServerAPI(T, ConnectionInfo) = is(typeof(
    {
        T session = T.startSession(ConnectionInfo.init);
        destroy(session);
    }));

unittest
{
    static class TestAPI
    {
        static TestAPI startSession(void* info)
        {
            return new TestAPI();
        }
    }
    assert(isServerAPI!(TestAPI, void*));
}

/**
 * Creates a server session. Runs and blocks the current task.
 * 
 * Throws: Throws exceptions on unrecoverable errors. In such cases the caller
 * should close the connection.
 */
ServerSession!API createServerSession(Implementation, API, ConnectionInfo)(Stream stream, ConnectionInfo info)
    if(isServerAPI!(Implementation, ConnectionInfo))
{
    auto api = Implementation.startSession(info);
    auto server = new ServerSession!API(api, stream);
    return server;
}

/*
 *
 */
class ServerSession(API)
{
    private:
        API _api;
        Stream _stream;
        // Need to make sure result and events are not interleaved
        TaskMutex _writeMutex;
        Task _runTask;

        void sendError(CallMessage info, ErrorType type,
            string msg = "", string file = "", size_t line = 0)
        {
            synchronized(_writeMutex)
            {
                serializeToJsonLine(_stream, ResponseType.error);
                auto err = ErrorMessage(info.id, type, msg, file, cast(uint)line);
                serializeToJsonLine(_stream, err);
                _stream.flush();
            }
        }

        /*
         * Note: handles recoverable errors internally by sending an error
         * to the remote client. Non-recoverable errors propagate as an
         * Exception and should cause the connection to the client to terminate.
         */
        void callMethod(string member)(CallMessage info)
        {
            alias overloads = MemberFunctionsTuple!(API, member);

            foreach(MethodType; overloads)
            {
                alias TParams = Parameters!MethodType;
                alias TRet = ReturnType!MethodType;
                enum mangle = typeof(MethodType).mangleof;
                TParams paramInst;

                if (info.parameters != TParams.length || info.mangle != mangle)
                {
                    continue;
                }

                size_t paramsRead = 0;
                try
                {
                    foreach(i, T; TParams)
                    {
                        paramsRead++;
                        paramInst[i] = _stream.deserializeJsonLine!(T)();
                    }
                }
                catch(Exception e)
                {
                    // If we failed to parse one parameter, skip rest of request
                    _stream.skipParameters(info.parameters - paramsRead);
                    debug
                        sendError(info, ErrorType.parameterMismatch, e.toString(), e.file, e.line);
                    else
                        sendError(info, ErrorType.parameterMismatch);
                    return;
                }

                static if(!is(TRet == void))
                    TRet result;

                try
                {
                    static if(!is(TRet == void))
                        mixin(`result = _api.` ~ member ~`(paramInst);`);
                    else
                        mixin(`_api.` ~ member ~`(paramInst);`);
                }
                catch (Exception e)
                {
                    // In case the member function called disconnect. If the same
                    // task called, there's no InterruptException thrown. Use the same
                    // code path nevertheless.
                    if (!connected)
                        throw new InterruptException();

                    debug
                        sendError(info, ErrorType.internalError, e.toString(), e.file, e.line);
                    else
                        sendError(info, ErrorType.internalError);
                    return;
                }

                // In case the member function called disconnect. If the same
                // task called, there's no InterruptException thrown. Use the same
                // code path nevertheless.
                if (!connected)
                    throw new InterruptException();

                // Write result Message
                synchronized(_writeMutex)
                {
                    serializeToJsonLine(_stream, ResponseType.result);
                    auto rMsg = ResultMessage(info.id, !is(TRet == void));
                    serializeToJsonLine(_stream, rMsg);
                    static if(!is(TRet == void))
                        serializeToJsonLine(_stream, result);
                    _stream.flush();
                }
                return;
            }

            // Haven't found any overload
            _stream.skipParameters(info.parameters);
            sendError(info, ErrorType.parameterMismatch);
            return;
        }

        void processCall()
        {
            auto info = _stream.deserializeJsonLine!CallMessage();


            foreach (member; __traits(derivedMembers, API))
            {
                // Guards against private members
                static if(__traits(compiles, __traits(getMember, API, member)))
                {
                    static if(isSomeFunction!(__traits(getMember, API, member))
                        && !hasUDA!(__traits(getMember, API, member), IgnoreUDA)
                        && !isSpecialFunction!member)
                    {
                        if (info.target == member)
                        {
                            callMethod!(member)(info);
                            return;
                        }
                    }
                }
            }

            // If we have not found a member, otherwise we returned already
            _stream.skipParameters(info.parameters);
            sendError(info, ErrorType.notImplemented);
        }

        /*
         * Returns:
         * false if remote send disconnect request.
         */
        bool processRequest()
        {
            auto type = _stream.deserializeJsonLine!RequestType();
            switch (type)
            {
                case RequestType.call:
                    processCall();
                    break;
                case RequestType.disconnect:
                    return false;
                default:
                    throw new Exception("Invalid request type");
            }
            return true;
        }

        void registerEvent(string name)()
        {
            alias EventType = ElementType!(typeof(__traits(getMember, API, name)));
            alias TRet = ReturnType!EventType;
            alias TArgs = Parameters!EventType;

            TRet onEvent(TArgs args)
            {
                assert(args.length < uint.max);

                enforceEx!DisconnectedException(connected);
                synchronized(_writeMutex)
                {
                    _stream.serializeToJsonLine(ResponseType.event);
                    auto msg = EventMessage(name, cast(uint)args.length);
                    _stream.serializeToJsonLine(msg);
                    foreach(arg; args)
                        _stream.serializeToJsonLine(arg);
                    _stream.flush();
                }

                static if(is(TRet == bool))
                    return true;
            }

            mixin(`_api.` ~ name ~` ~= &onEvent;`);
        }

        void registerEvents()
        {
            foreach (member; __traits(derivedMembers, API))
            {
                // Guards against private members
                static if(__traits(compiles, __traits(getMember, API, member)))
                {
                    static if(isEmittable2!(typeof(__traits(getMember, API, member))) &&
                         !hasUDA!(__traits(getMember, _api, member), IgnoreUDA))
                    {
                        registerEvent!member;
                    }
                }
            }
        }

        /*
         * 
         */
        this(API api, Stream stream)
        {
            _writeMutex = new TaskMutex();
            _api = api;
            _stream = stream;
            registerEvents();
        }

        /*
        * We were somehow disconnected. Clean up all tasks and notify waiting
        * calls by throwing Exceptions.
        */
        void shutdown() nothrow
        {
            if (_stream)
            {
                _stream = null;
            }

            collectException(destroy(_api));

            // Do this as the last thing: After run returns the _stream may become
            // invalid
            if(_runTask != Task.getThis)
                collectException(_runTask.interrupt());
        }

    public:
        /**
        * Whether client session is still connected.
        * Note: This does not necessarily mean the underlying stream is closed.
        */
        @property bool connected()
        {
            return _stream !is null;
        }

        /*
         * 
         */
        void run()
        {
            _runTask = Task.getThis();
            try
            {
                bool next;
                do
                {
                    next = processRequest();
                }
                while(next);

                shutdown();
            }
            catch (InterruptException)
            {
                // OK
            }
            catch(Exception e)
            {
                shutdown();
                throw e;
            }
        }

        /**
        * Sends disconnect signal to remote server and stops internal tasks.
        * 
        * Note: Do not call any functions on this instance after disconnecting.
        * Emitting further events will throw DisconnectedExceptions. The API instance
        * will get destroy() ed.
        *
        * This does not close the underlying stream.
        */
        void disconnect()
        {
            if(!connected)
                return;

            synchronized(_writeMutex)
            {
                _stream.serializeToJsonLine(ResponseType.disconnect);
                _stream.flush();
                shutdown();
            }
        }
}
