vibe-rpcchannel
================

[![Coverage Status](https://coveralls.io/repos/github/jpf91/vibe-rpcchannel/badge.svg?branch=master)](https://coveralls.io/github/jpf91/vibe-rpcchannel?branch=master)
[![Build Status](https://travis-ci.org/jpf91/vibe-rpcchannel.svg?branch=master)](https://travis-ci.org/jpf91/vibe-rpcchannel)

This implements a simple D-only RPC mechanism for [vibe.D](http://vibed.org/). The
library is designed to be generic and work with any transport stream. Easy to use
wrappers are available for unencrypted TCP streams and [vibe-noisestream](https://github.com/jpf91/vibe-noisestream) encrypted
noise channels.


The API documentation is available [here](https://jpf91.github.io/vibe-rpcchannel/vibe/rpcchannel/tcp.html).

Features
--------
* Events allow for server->client communication callbacks
* Overloading for functions
* API enabled easy management of sessions and authentication
* API is flexible enough to allow for _reverse mode_: The machine connecting
  to a remote machine can be the RPC server. This is useful for NATed machines.

Limitations:
------------
vibe-rpcchannel is more of a method to quickly build client<->server messaging
protocols than a general purpose RPC server. This means especially that only
one RPC call can be processed at a time. Also there's only limited Exception
handling: All server side exceptions map to an RPCException at the client.
Use error return values instead.

A simple TCP server/client example
----------------------------------

```d
import vibe.d, vibe.rpcchannel;

abstract class API
{
    int request(int a);
    string request(string a);
    
    Event!(int) progress;
    Event!() timer;

    void startTimer();
    void stopTimer();


    @ignoreRPC void ignoredFunction() {};
    @ignoreRPC void ignoredEvent();
}

class APIServer : API
{
    bool _timerStop = false;

    static APIServer startSession(TCPConnection info)
    {
        // Use info for authentication
        return new APIServer();
    }
    
    override int request(int a)
    {
        progress.emit(1);
        progress.emit(2);
        progress.emit(3);
        return a;
    }

    override string request(string a)
    {
        progress.emit(4);
        return a;
    }

    override void startTimer()
    {
        runTask(()
        {
            while (!_timerStop)
            {
                timer.emit();
                sleep(100.msecs);
            }
        });
    }
    
    override void stopTimer()
    {
        _timerStop = true;
    }
}

void main()
{
    void clientMain()
    {
        auto client = clientTCP!(API)("localhost", 8030);
        client.progress ~= (int a) {writeln("Progress event: ", a);};
        client.timer ~= () {writeln("Timer event");};
        assert(client.request(42) == 42);
        assert(client.request("hello") == "hello");
        client.startTimer();
        client.stopTimer();
        client.closeTCP();
    }

    auto server = serveTCP!(APIServer, API)(8030);
    runTask(&clientMain);
    runEventLoop();
}
```
