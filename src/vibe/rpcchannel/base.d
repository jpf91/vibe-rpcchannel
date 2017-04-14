/**
 * Contains data types and functions required by both vibe.rcpchannel.server
 * and vibe.rpcchannel.client.
 *
 * Protocol related definitions are kept in vibe.rpcchannel.protocol.
 */
module vibe.rpcchannel.base;

import vibe.core.stream;
import vibe.core.sync;

import std.traits;
import std.range : ElementType;

import vibe.rpcchannel.protocol;

/*
 * UDA to ignore a method or event when generating RPC stubs.
 * 
 * Note: Do not use this directly, use ignoreRPC instead.
 * Example:
 * -------------------------
 * @ignoreRPC void ignoreThis();
 * -------------------------
 */
struct IgnoreUDA
{
}

/**
 * UDA to ignore a method or event when generating RPC stubs.
 * 
 * Example:
 * -------------------------
 * @ignoreRPC void ignoreThis();
 * -------------------------
 */
enum ignoreRPC = IgnoreUDA.init;

/**
 * Exception thrown when a RPC error occurs.
 * 
 * This exception can be thrown by any of the client or server management
 * methods (such as disconnect), by all client functions calling a remote
 * RPC function and by all `event.emit()` calls on a server.
 */
class RPCException : Exception
{
    public
    {
        /**
         * Construct a new RPCException.
         */
        @safe pure nothrow this(string message, string file = __FILE__,
            size_t line = __LINE__, Throwable next = null)
        {
            super(message, file, line, next);
        }
    }
}

/**
 * Exception thrown if the connection to the remote side was closed.
 *
 * Note: This is a higher layer concept does not imply that the underlying stream is closed.
 */
class DisconnectedException : RPCException
{
    public
    {
        /**
         * Construct a new DisconnectedException.
         */
        @safe pure nothrow this(string message = "Connection disconnected",
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
        {
            super(message, file, line, next);
        }
    }
}

/**
 * Checks whether some type is a emittable type of the tinyevent library, i.e.
 * whether `Type.init.emit()` is working.
 */
enum bool isEmittable2(T) = isArray!T && isDelegate!(ElementType!T)
        && (is(ReturnType!(ElementType!T) == bool) || is(ReturnType!(ElementType!T) == void));

/**
 * Checks whether name is the name of a special function which should be IgnoreUDA
 * when generating RPC methods. Ignores `startSession`, constructors, destructors,
 * `toHash` and `toString`.
 */
enum bool isSpecialFunction(string name) = name == "startSession"
        || name == "__dtor" || (name.length >= 6 && name[0 .. 5] == "__ctor"
        || name == "toHash" || name == "toString");
