module test;

import std.exception;
import vibe.d, vibe.rpcchannel;
import tinyevent;

version (unittest)  : import std.stdio;

// Hack. Well for testing this should be OK ;-)
TCPServer!(APIServer, API) server;

struct TestStruct
{
    int a;
    string[] b;
}

abstract class API
{
    /// Test return values, parameters, overloading
    void request1();
    /// ditto
    int request1(int a);
    /// ditto
    int request2(int[] a);
    /// ditto
    int request2(TestStruct s);
    /// ditto
    int getCounter();
    /// ditto
    TestStruct getStruct();
    /// emit a event on the server which is not emitted to clients
    void emitIgnoredEvent();

    /// Test events
    Event!() voidEvent;
    Event!(int) intEvent;
    Event!(int, int) twoEvent;
    /// This event is emitted from a free-running counter
    Event!() counterEvent;

    /// Call all events
    void testEvents();

    @ignoreRPC Event!() ignoredEvent;

    @ignoreRPC int ignoredFunction()
    {
        return 42;
    }

    /// stop the server
    void stopServer();

    /// stop the server and exception
    void stopServerException();

    /// Throw
    void remoteException();

    void startEvents();

    void stopEvents();
}

size_t numDestroyed = 0;

class APIServer : API
{
    int counter;
    TCPConnection _info;
    bool _eventStop = false;

    this(TCPConnection info)
    {
        _info = info;
    }

    static APIServer startSession(TCPConnection info)
    {
        return new APIServer(info);
    }

    override void request1()
    {
        counter = 10;
    }

    override int request1(int a)
    {
        counter += a;
        return counter;
    }

    override int request2(int[] a)
    {
        counter += a.length;
        return counter;
    }

    override int request2(TestStruct s)
    {
        counter += s.a;
        counter += s.b.length;
        return counter;
    }

    override int getCounter()
    {
        return counter;
    }

    override TestStruct getStruct()
    {
        TestStruct result;
        result.a = 42;
        result.b = ["a", "b"];
        return result;
    }

    override void emitIgnoredEvent()
    {
        ignoredEvent.emit();
    }

    override int ignoredFunction()
    {
        return 0;
    }

    override void testEvents()
    {
        voidEvent.emit();
        intEvent.emit(42);

        Timer timer;
        int i = 0;
        timer = setTimer(10.msecs, ()
        {
            counterEvent.emit(); if (++i == 3)
                timer.stop();
        }, true);
    }

    override void stopServer()
    {
        // Hack. Well for testing this should be OK ;-)
        server.stop();
    }

    override void stopServerException()
    {
        // Hack. Well for testing this should be OK ;-)
        server.stop();
        throw new Exception("");
    }

    override void remoteException()
    {
        throw new Exception("A error message");
    }

    override void startEvents()
    {

        runTask(()
        {
            while (!_eventStop)
            {
                counterEvent.emit();
                sleep(10.usecs);
            }
        });
    }

    override void stopEvents()
    {
        _eventStop = true;
    }

    ~this()
    {
        numDestroyed++;
    }
}

// Test basic functions
unittest
{
    uint done = 0;

    void clientMain()
    {
        try
        {
            scope (exit)
            {
                done++;
                if (done == 3)
                {
                    // We eant to test that the client disconnects first!
                    sleep(10.msecs);
                    assert(numDestroyed == 3);
                    server.stop();
                    exitEventLoop();
                }
            }

            auto client = clientTCP!(API)("localhost", 8030);
            client.request1();
            assert(client.getCounter() == 10);
            assert(client.request1(10) == 20);
            assert(client.getCounter() == 20);
            assert(client.request2([1, 3]) == 22);
            assert(client.getCounter() == 22);
            assert(client.request2(TestStruct(6, ["1", "2"])) == 30);
            assert(client.getCounter() == 30);
            assert(client.getStruct() == TestStruct(42, ["a", "b"]));

            // Test events
            bool voidCalled, intCalled;
            size_t counter = 0;
            client.voidEvent ~= ()
            {
                voidCalled = true;
            };
            client.intEvent ~= (int a)
            {
                assert(a == 42);
                intCalled = true;
            };
            client.counterEvent ~= ()
            {
                counter++;
            };
            client.testEvents();
            // Other request parallel to counterEvent
            client.getCounter();
            // wait till counterEvents are done
            sleep(100.msecs);
            assert(voidCalled);
            assert(intCalled);
            assert(counter == 3);

            // Server would return 0, local returns 42
            assert(client.ignoredFunction() == 42);
            client.ignoredEvent ~= ()
            {
                assert(false, "Event should be ignored");
            };
            client.emitIgnoredEvent();
            client.closeTCP();
        }
        catch (Exception e)
            assert(false, "Should not throw: " ~ e.toString());
    }

    numDestroyed = 0;
    server = serveTCP!(APIServer, API)(8030);
    runTask( & clientMain);
    runTask( & clientMain);
    runTask( & clientMain);
    runEventLoop();
}

// Test error handling
unittest
{
    void clientMain()
    {
        try
        {
            scope (exit)
            {
                server.stop();
                exitEventLoop();
            }

            auto client = clientTCP!(API)("localhost", 8030);
            assertThrown!RPCException(client.remoteException());
            auto e = collectException!RPCException(client.remoteException);
            debug
            {
                import std.algorithm : canFind;

                // Contains complete backtrace
                assert(e.msg.canFind("A error message"));
                assert(e.file.canFind("test.d"));
                assert(e.line == 159);
            }

            client.closeTCP();
        }
        catch (Exception e)
            assert(false, "Should not throw: " ~ e.toString());
    }

    server = serveTCP!(APIServer, API)(8030);
    runTask( & clientMain);
    runEventLoop();
}

// Test error handling in client, invalid server responses
unittest
{
    TCPListener[] listener;

    void clientMain()
    {
        try
        {
            scope (exit)
            {
                foreach (l; listener)
                    l.stopListening();
                exitEventLoop();
            }

            auto client = clientTCP!(API)("localhost", 8030);
            client.twoEvent ~= (int, int)
            {
                assert(false, "Shouldn't get called");
            };
            bool called = false;
            client.onDisconnect ~= (RPCClient!(API, TCPConnection))
            {
                called = true;
            };
            // Real return value is int, here typed as void
            client.request1();
            // Test proper recovery
            client.request1();

            // Test wrong result type
            assertThrown(client.request1(42));
            assert(client.connected);
            assert(!called);

            client.request1();

            client.closeTCP();
        }
        catch (Exception e)
            assert(false, "Should not throw: " ~ e.toString());
    }

    listener = listenTCP(8030, delegate(TCPConnection conn)
    {
        import vibe.rpcchannel.protocol;

        uint readCall()
        {
            auto type = conn.deserializeJsonLine!RequestType(); auto call = conn
                .deserializeJsonLine!CallMessage(); for (size_t i = 0; i < call.parameters;
                        i++)
                    conn.deserializeJsonLine!void(); return call.id;}

            // Client expects void result
            auto id = readCall(); conn.serializeToJsonLine(ResponseType.result);
                conn.serializeToJsonLine(ResultMessage(id, true)); conn.serializeToJsonLine(
                42); // Send an event with wrong number of parameters
                conn.serializeToJsonLine(ResponseType.event); conn.serializeToJsonLine(
                EventMessage("twoEvent", 1)); conn.serializeToJsonLine("wrong type!");

                // Send an event with wrong type of parameter
                conn.serializeToJsonLine(ResponseType.event); conn.serializeToJsonLine(
                EventMessage("twoEvent", 2)); conn.serializeToJsonLine("wrong type!");
                conn.serializeToJsonLine(42); id = readCall(); conn.serializeToJsonLine(
                ResponseType.result); conn.serializeToJsonLine(ResultMessage(id,
                true)); conn.serializeToJsonLine(42); // Client expects int result
                id = readCall(); conn.serializeToJsonLine(ResponseType.result);
                conn.serializeToJsonLine(ResultMessage(id, true)); conn.serializeToJsonLine(
                "0"); // Client expects void result
                id = readCall(); conn.serializeToJsonLine(ResponseType.result);
                conn.serializeToJsonLine(ResultMessage(id, true)); conn.serializeToJsonLine(
                42);});

            runTask( & clientMain);
            runEventLoop();
        }

        // Test error handling in client, invalid protocol
        unittest
        {
            TCPListener[] listener;

            int clientsDone = 0;

            void clientMain(int mode)()
            {
                try
                {
                    scope (exit)
                    {
                        if (++clientsDone == 4)
                        {
                            foreach (l; listener)
                                l.stopListening();
                            exitEventLoop();
                        }
                    }

                    auto client = clientTCP!(API)("localhost", 8030);
                    bool called = false;
                    client.onDisconnect ~= (RPCClient!(API, TCPConnection))
                    {
                        called = true;
                    };

                    static if (mode == 0)
                    {
                        // Server sends invalid message type
                        assertThrown(client.request1(mode));
                    }
                    static if (mode == 1)
                    {
                        // Server sends invalid event body type
                        assertThrown(client.request1(mode));
                    }
                    static if (mode == 2)
                    {
                        // Server sends invalid message body
                        assertThrown(client.request1(mode));
                    }
                    static if (mode == 3)
                    {
                        // Server sends invalid error body
                        assertThrown(client.request1(mode));
                    }
                    assert(called);
                    assert(!client.connected);

                    client.closeTCP();
                }
                catch (Exception e)
                    assert(false, "Should not throw: " ~ e.toString());
            }

            listener = listenTCP(8030, delegate(TCPConnection conn)
            {
                import vibe.rpcchannel.protocol;

                uint mode = 0; uint readCall()
                {
                    auto type = conn.deserializeJsonLine!RequestType(); auto call = conn
                        .deserializeJsonLine!CallMessage(); mode = conn.deserializeJsonLine!int();
                    return call.id;}

                    // Client expects void result
                    auto id = readCall(); switch (mode)
                    {
                    case 0 : conn.serializeToJsonLine(42); break; case 1 : conn.serializeToJsonLine(
                            ResponseType.event); conn.serializeToJsonLine("Hello");
                        break; case 2 : conn.serializeToJsonLine(ResponseType.result);
                            conn.serializeToJsonLine("Hello"); break; case 3 : conn.serializeToJsonLine(
                            ResponseType.error); conn.serializeToJsonLine("Hello");
                            break; default : break;}
                    });

                    runTask( & clientMain!0);
                    runTask( & clientMain!1);
                    runTask( & clientMain!2);
                    runTask( & clientMain!3);
                    runEventLoop();
                }

                // Test disconnects
                // Server disconnect, from external task
                unittest
                {
                    void clientMain()
                    {
                        try
                        {
                            scope (exit)
                            {
                                exitEventLoop();
                            }

                            auto addr = resolveHost("127.0.0.1");
                            addr.port = 8030;
                            bool called = false;
                            auto client = clientTCP!(API)(addr);
                            client.onDisconnect ~= (RPCClient!(API, TCPConnection))
                            {
                                called = true;
                            };
                            server.stop();
                            sleep(10.msecs);
                            assert(called);
                            assertThrown!DisconnectedException(client.getCounter());
                            called = false;
                            client.closeTCP();
                            assert(!called);
                        }
                        catch (Exception e)
                            assert(false, "Should not throw: " ~ e.toString());
                    }

                    server = serveTCP!(APIServer, API)(8030, "127.0.0.1");
                    runTask( & clientMain);
                    runEventLoop();
                }

                // Server disconnect, from same task
                unittest
                {
                    void clientMain()
                    {
                        try
                        {
                            scope (exit)
                            {
                                exitEventLoop();
                            }

                            bool called = false;
                            auto client = clientTCP!(API)("localhost", 8030);
                            client.onDisconnect ~= (RPCClient!(API, TCPConnection))
                            {
                                called = true;
                            };
                            // Disconnects before server sends result
                            assertThrown!DisconnectedException(client.stopServer());
                            sleep(10.msecs);
                            assert(called);
                            assertThrown!DisconnectedException(client.getCounter());
                            called = false;
                            client.closeTCP();
                            assert(!called);
                        }
                        catch (Exception e)
                            assert(false, "Should not throw: " ~ e.toString());
                    }

                    server = serveTCP!(APIServer, API)(8030);
                    runTask( & clientMain);
                    runEventLoop();
                }

                // Server disconnect and exception, from same task
                unittest
                {
                    void clientMain()
                    {
                        try
                        {
                            scope (exit)
                            {
                                exitEventLoop();
                            }

                            bool called = false;
                            auto client = clientTCP!(API)("localhost", 8030);
                            client.onDisconnect ~= (RPCClient!(API, TCPConnection))
                            {
                                called = true;
                            };
                            // Disconnects before server sends result
                            assertThrown!DisconnectedException(client.stopServerException());
                            sleep(10.msecs);
                            assert(called);
                            assertThrown!DisconnectedException(client.getCounter());
                            called = false;
                            client.closeTCP();
                            assert(!called);
                        }
                        catch (Exception e)
                            assert(false, "Should not throw: " ~ e.toString());
                    }

                    server = serveTCP!(APIServer, API)(8030);
                    runTask( & clientMain);
                    runEventLoop();
                }

                // Test error handling in server, invalid client requests
                unittest
                {
                    import vibe.rpcchannel.protocol;

                    void clientMain()
                    {
                        try
                        {
                            scope (exit)
                            {
                                server.stop();
                                exitEventLoop();
                            }

                            auto conn = connectTCP("127.0.0.1", 8030);

                            void readError()
                            {
                                auto type = conn.deserializeJsonLine!ResponseType();
                                assert(type == ResponseType.error);
                                auto err = conn.deserializeJsonLine!ErrorMessage();
                            }

                            // Wrong number of parameters
                            conn.serializeToJsonLine(RequestType.call);
                            conn.serializeToJsonLine(CallMessage(0, "request1",
                                "FiZi", 0));
                            readError();

                            // Wrong parameter type
                            conn.serializeToJsonLine(RequestType.call);
                            conn.serializeToJsonLine(CallMessage(0, "request1",
                                "FiZi", 1));
                            conn.serializeToJsonLine("Hello");
                            readError();

                            // Unknown mangle
                            conn.serializeToJsonLine(RequestType.call);
                            conn.serializeToJsonLine(CallMessage(0, "request1",
                                "abcd", 3));
                            conn.serializeToJsonLine("Hello");
                            conn.serializeToJsonLine(42);
                            conn.serializeToJsonLine(ErrorMessage.init);
                            readError();

                            // Unknown function
                            conn.serializeToJsonLine(RequestType.call);
                            conn.serializeToJsonLine(CallMessage(0,
                                "request1abcd", "abcd", 3));
                            conn.serializeToJsonLine("Hello");
                            conn.serializeToJsonLine(42);
                            conn.serializeToJsonLine(ErrorMessage.init);
                            readError();

                            conn.close();
                        }
                        catch (Exception e)
                            assert(false, "Should not throw: " ~ e.toString());
                    }

                    server = serveTCP!(APIServer, API)(8030);
                    runTask( & clientMain);
                    runEventLoop();
                }

                // Test error handling in server, invalid protocol
                unittest
                {
                    import vibe.rpcchannel.protocol;

                    size_t clientDone;
                    void clientMain(int mode)()
                    {
                        try
                        {
                            scope (exit)
                            {
                                if (++clientDone == 2)
                                {
                                    assert(numDestroyed == 2);
                                    server.stop();
                                    exitEventLoop();
                                }
                            }

                            auto conn = connectTCP("127.0.0.1", 8030);

                            static if (mode == 0)
                            {
                                // Invalid request
                                conn.serializeToJsonLine(42);
                                collectException(conn.deserializeJsonLine!int());
                            }
                            else
                            {
                                // Invalid call body
                                conn.serializeToJsonLine(RequestType.call);
                                conn.serializeToJsonLine("foo");
                            }

                            conn.close();
                        }
                        catch (Exception e)
                            assert(false, "Should not throw: " ~ e.toString());
                    }

                    numDestroyed = 0;
                    server = serveTCP!(APIServer, API)(8030);
                    runTask( & clientMain!0);
                    runTask( & clientMain!1);
                    runEventLoop();
                }

                // Test heavy event / call interleaving to make sure data does not get
                // interleaved on the connection
                // Test basic functions
                unittest
                {
                    uint done = 0;

                    void clientMain()
                    {
                        try
                        {
                            scope (exit)
                            {
                                done++;
                                if (done == 100)
                                {
                                    // We eant to test that the client disconnects first!
                                    sleep(10.msecs);
                                    server.stop();
                                    exitEventLoop();
                                }
                            }

                            auto client = clientTCP!(API)("localhost", 8030);
                            client.startEvents();
                            for (size_t i = 0; i < 1000; i++)
                            {
                                client.request1();
                            }
                            client.stopEvents();

                            client.closeTCP();
                        }
                        catch (Exception e)
                            assert(false, "Should not throw: " ~ e.toString());
                    }

                    server = serveTCP!(APIServer, API)(8030);
                    for (size_t i = 0; i < 100; i++)
                        runTask( & clientMain);
                    runEventLoop();
                }
