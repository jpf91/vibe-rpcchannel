/**
 * Provides high level interface for TCP based RPC.
 *
 */
module vibe.rpcchannel.tcp;

import vibe.core.net;
import vibe.rpcchannel.server;
import vibe.rpcchannel.client;

/**
 * The RPC server implementation using a unencrypted TCPConnection transport stream.
 */
class TCPServer(Implementation, API)
{
    static struct TCPServerSession
    {
        ServerSession!API session;
        TCPConnection conn;
    }

private:
    TCPListener[] _listener;
    TCPServerSession[] _sessions;

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
        TCPServerSession tcp;
        tcp.session = createServerSession!(Implementation, API)(conn, conn);
        tcp.conn = conn;
        _sessions ~= tcp;
        scope (exit)
        {
            onDisconnect(tcp.session);
        }
        tcp.session.run();
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
 * Create a new TCP based API server.
 */
TCPServer!(Implementation, API) serveTCP(Implementation, API)(ushort port) if (
        isServerAPI!(Implementation, TCPConnection))
{
    auto server = new TCPServer!(Implementation, API)();
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
        static Implementation startSession(TCPConnection conn)
        {
            return new Implementation();
        }

        override string someMethod(string name)
        {
            return "Hello " ~ name ~ "!";
        }
    }

    auto server = serveTCP!(Implementation, API)(8030);
    server.stop();
}

/// ditto
TCPServer!(Implementation, API) serveTCP(Implementation, API)(ushort port, string address) if (
        isServerAPI!(Implementation, TCPConnection))
{
    auto server = new TCPServer!(Implementation, API)();
    server._listener = [listenTCP(port, &server.onTCPConnect, address)];
    return server;
}

/**
 * An alias for a TCP based RPCClient.
 */
template TCPClient(API)
{
    alias TCPClient = RPCClient!(API, TCPConnection);
}

/**
 * Connect to a remote, TCP based API server.
 *
 * Examples:
 * -------
 * abstract static class API
 * {
 *     string someMethod(string name);
 * }
 * auto client = clientTCP!API("127.0.0.1", 8030);
 * client.someMethod("john");
 * client.closeTCP();
 * ------
 */
auto clientTCP(API)(string host, ushort port, string bind_interface = null,
    ushort bind_port = cast(ushort) 0u)
{
    auto stream = connectTCP(host, port, bind_interface, bind_port);
    return createClientSession!(API, TCPConnection)(stream, stream);
}

/// ditto
auto clientTCP(API)(NetworkAddress addr, NetworkAddress bind_address = anyAddress())
{
    auto stream = connectTCP(addr, bind_address);
    return createClientSession!(API, TCPConnection)(stream, stream);
}

/**
 * Completely close the connections maintained by a TCPClient
 */
void closeTCP(Client)(Client client)
{
    client.disconnect();
    if (client.connectionInfo.connected)
        client.connectionInfo.close();
}
