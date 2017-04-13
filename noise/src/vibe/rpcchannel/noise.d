module vibe.rpcchannel.noise;

import vibe.core.net;
import vibe.noise;
import vibe.rpcchannel.server;
import vibe.rpcchannel.client;

struct NoiseInfo
{
    NoiseStream stream;
    TCPConnection conn;
}

class NoiseServer(Implementation, API)
{
    static struct NoiseServerSession
    {
        ServerSession!API session;
        TCPConnection conn;
    }

private:
    TCPListener[] _listener;
    NoiseServerSession[] _sessions;
    NoiseSettings _noiseSettings;

    /*
     * Called if other side disconnected first
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
     * Called when TCP listener receives a new connection
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

NoiseServer!(Implementation, API) serveNoise(Implementation, API)(NoiseSettings settings,
    ushort port) if (isServerAPI!(Implementation, NoiseInfo))
{
    auto server = new NoiseServer!(Implementation, API)();
    server._noiseSettings = settings;
    server._listener = listenTCP(port, &server.onTCPConnect);
    return server;
}

NoiseServer!(Implementation, API) serveNoise(Implementation, API)(
    NoiseSettings settings, ushort port, string address) if (
        isServerAPI!(Implementation, NoiseInfo))
{
    auto server = new NoiseServer!(Implementation, API)();
    server._noiseSettings = settings;
    server._listener = [listenTCP(port, &server.onTCPConnect, address)];
    return server;
}

template NoiseClient(API)
{
    alias NoiseClient = RPCClient!(API, NoiseInfo);
}

auto clientNoise(API)(NoiseSettings settings, string host, ushort port,
    string bind_interface = null, ushort bind_port = cast(ushort) 0u)
{
    auto conn = connectTCP(host, port, bind_interface, bind_port);
    auto stream = conn.createNoiseStream(settings);
    return createClientSession!(API, NoiseInfo)(stream, NoiseInfo(stream, conn));
}

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
