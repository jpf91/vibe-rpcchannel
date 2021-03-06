/**
 * Encrypted RPC using vibe-noisestream.
 *
 * This module provides RPC client and server using encrypted noise streams.
 * This requires the vibe-noisestream library and this module is therefore
 * in an extra dub subpackage: vibe-rpcchannel:noise.
 */
module vibe.rpcchannel.noise;

import vibe.core.net;
import vibe.noise;
import vibe.rpcchannel.server;
import vibe.rpcchannel.client;

/**
 * Information about a noise connection.
 * 
 * Contains the TCPConnection as well as the NoiseStream. The NoiseStream can
 * be queried for the public key of the remote end using the remoteKey property.
 * This can be used to implement public key based authentication.
 */
struct NoiseInfo
{
    NoiseStream stream;
    TCPConnection conn;
}

/**
 * The RPC server implementation using an encrypted vibe-noisestream transport stream.
 */
class NoiseServer(Implementation, API)
{
private:
    static struct NoiseServerSession
    {
        ServerSession!API session;
        TCPConnection conn;
    }

    TCPListener[] _listener;
    NoiseServerSession[] _sessions;
    NoiseSettings _noiseSettings;

    /*
     * Called if other side disconnected first.
     */
    void onDisconnect(ServerSession!API session)
    {
        size_t j = 0;
        for (size_t i = 0; i < _sessions.length; i++)
        {
            if (_sessions[i].session != session)
            {
                _sessions[j] = _sessions[i];
                j++;
            }
        }
        _sessions.length = j;
    }

    /*
     * Called when TCP listener receives a new connection.
     */
    void onTCPConnect(TCPConnection conn)
    {
        NoiseServerSession server;

        auto stream = conn.createNoiseStream(_noiseSettings);

        server.session = createServerSession!(Implementation, API)(stream, NoiseInfo(stream,
            conn));
        server.conn = conn;
        _sessions ~= server;
        scope (exit)
        {
            stream.finalize();
            onDisconnect(server.session);
        }
        server.session.run();
    }

public:
    /**
     * Stop listening for new connections and cleanly disconnect all
     * existing connections.
     */
    void stop()
    {
        foreach (listener; _listener)
            listener.stopListening();

        foreach (session; _sessions)
        {
            session.session.disconnect();
        }
    }
}

/**
 * Create a new vibe-noisestream based API server.
 */
NoiseServer!(Implementation, API) serveNoise(Implementation, API)(NoiseSettings settings,
    ushort port) if (isServerAPI!(Implementation, NoiseInfo))
{
    auto server = new NoiseServer!(Implementation, API)();
    server._noiseSettings = settings;
    server._listener = listenTCP(port, &server.onTCPConnect);
    return server;
}

///
unittest
{
    abstract static class API
    {
        string someMethod(string name);
    }

    static class Implementation : API
    {
        static Implementation startSession(NoiseInfo info)
        {
            return new Implementation();
        }

        override string someMethod(string name)
        {
            return "Hello " ~ name ~ "!";
        }
    }

    // See vibe-noisestream for how to generate keys
    createKeys("server.key", "server.pub");
    createKeys("client.key", "client.pub");

    // Need to set settings correctly. See vibe-noisestream documentation
    // for more information. It's also possible to use a callback for remote
    // key verification.
    auto settings = NoiseSettings(NoiseKind.server);
    settings.privateKeyPath = Path("server.key");
    settings.remoteKeyPath = Path("client.pub");

    auto server = serveNoise!(Implementation, API)(settings, 8030);
    server.stop();
}

///ditto
NoiseServer!(Implementation, API) serveNoise(Implementation, API)(
    NoiseSettings settings, ushort port, string address) if (
        isServerAPI!(Implementation, NoiseInfo))
{
    auto server = new NoiseServer!(Implementation, API)();
    server._noiseSettings = settings;
    server._listener = [listenTCP(port, &server.onTCPConnect, address)];
    return server;
}

/**
 * An alias for a vibe-noisestream based RPCClient.
 */
template NoiseClient(API)
{
    alias NoiseClient = RPCClient!(API, NoiseInfo);
}

/**
 * Connect to a remote, vibe-noisestream based API server.
 *
 * Examples:
 * -------
 * abstract static class API
 * {
 *     string someMethod(string name);
 * }
 *
 * auto settings = NoiseSettings(NoiseKind.client);
 * settings.privateKeyPath = Path("client.key");
 * settings.remoteKeyPath = Path("server.pub");
 *
 * auto client = clientNoise!API(settings, "127.0.0.1", 8030);
 * client.someMethod("john");
 * client.closeTCP();
 * ------
 */
auto clientNoise(API)(NoiseSettings settings, string host, ushort port,
    string bind_interface = null, ushort bind_port = cast(ushort) 0u)
{
    auto conn = connectTCP(host, port, bind_interface, bind_port);
    auto stream = conn.createNoiseStream(settings);
    return createClientSession!(API, NoiseInfo)(stream, NoiseInfo(stream, conn));
}

///ditto
auto clientNoise(API)(NoiseSettings settings, NetworkAddress addr,
    NetworkAddress bind_address = anyAddress())
{
    auto conn = connectTCP(addr, bind_address);
    auto stream = conn.createNoiseStream(settings);
    return createClientSession!(API, NoiseInfo)(stream, NoiseInfo(stream, conn));
}

void closeNoise(Client)(Client client)
{
    client.disconnect();
    client.connectionInfo.stream.finalize();
    if (client.connectionInfo.conn.connected)
    {
        client.connectionInfo.conn.close();
    }
}

version (unittest)
{
    import vibe.d, tinyevent, std.stdio;

    abstract class API
    {
        void request1();
        void startEvents();
        void stopEvents();
        Event!() counterEvent;
    }

    class APIServer : API
    {
        NoiseInfo _info;
        bool _eventStop = false;

        this(NoiseInfo info)
        {
            _info = info;
        }

        static APIServer startSession(NoiseInfo info)
        {
            return new APIServer(info);
        }

        override void request1()
        {
        }

        override void startEvents()
        {
            runTask(() {
                while (!_eventStop)
                {
                    counterEvent.emit();
                    sleep(1000.usecs);
                }
            });
        }

        override void stopEvents()
        {
            _eventStop = true;
        }
    }
}

// Test heavy event / call interleaving to make sure data does not get
// interleaved on the connection
// Test basic functions
unittest
{
    uint done = 0;
    NoiseServer!(APIServer, API) server;

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

            auto settings = NoiseSettings(NoiseKind.client);
            settings.privateKeyPath = Path("client.key");
            settings.remoteKeyPath = Path("server.pub");
            auto client = clientNoise!(API)(settings, "localhost", 8020);
            client.startEvents();
            for (size_t i = 0; i < 100; i++)
            {
                client.request1();
            }
            client.stopEvents();
            client.closeNoise();
        }
        catch (Exception e)
            assert(false, "Should not throw: " ~ e.toString());
    }

    createKeys("server.key", "server.pub");
    createKeys("client.key", "client.pub");

    auto settings = NoiseSettings(NoiseKind.server);
    settings.privateKeyPath = Path("server.key");
    settings.remoteKeyPath = Path("client.pub");

    server = serveNoise!(APIServer, API)(settings, 8020);
    for (size_t i = 0; i < 100; i++)
        runTask(&clientMain);
    runEventLoop();
}
