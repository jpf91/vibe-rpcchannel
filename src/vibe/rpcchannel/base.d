/**
 * Contains data types and functions required by both vibe.rcpchannel.server
 * and vibe.rpcchannel.client.
 *
 * Protocol related definitions are kept in vibe.rpcchannel.protocol.
 */
module vibe.rpcchannel.base;

import vibe.core.stream;
import vibe.core.sync;

import std.traits, std.meta;
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

/**
 * Returns a tuple of overloads for function member in API
 * which will be implemented by the RPC server and client.
 */
template APIFunctionOverloads(API, string member)
{
    alias APIFunctionOverloads = MemberFunctionsTuple!(API, member);
}

/**
 * Returns a tuple of all overloads for all functions in API which will be
 * implemented by the RPC server and client.
 */
template APIOverloads(API)
{
    enum derivedMembers = APIFunctions!API;
    template OverloadMap(string member)
    {
        alias OverloadMap = APIFunctionOverloads!(API, member);
    }

    alias APIOverloads = staticMap!(OverloadMap, derivedMembers);
}

/**
 * Returns a string tuple of all function members in API which will be
 * implemented by the RPC server and client.
 */
template APIFunctions(API)
{
    enum derivedMembers = __traits(derivedMembers, API);

    template isValidMember(string member)
    {
        // Guards against private members
        static if (__traits(compiles, __traits(getMember, API, member)))
        {
            static if (isSomeFunction!(__traits(getMember, API, member))
                       && !hasUDA!(__traits(getMember, API, member), IgnoreUDA)
                       && !isSpecialFunction!member)
            {
                enum isValidMember = true;
            }
            else
            {
                enum isValidMember = false;
            }
        }
        else
        {
            enum isValidMember = false;
        }
    }

    alias APIFunctions = Filter!(isValidMember, derivedMembers);
}

/**
 * Returns a string tuple of all event members in API which will be
 * implemented by the RPC server and client.
 */
template APIEvents(API)
{
    enum derivedMembers = __traits(derivedMembers, API);

    template isValidMember(string member)
    {
        // Guards against private members
        static if (__traits(compiles, __traits(getMember, API, member)))
        {
            static if (isEmittable2!(typeof(__traits(getMember, API, member)))
                       && !hasUDA!(__traits(getMember, API, member), IgnoreUDA))
            {
                enum isValidMember = true;
            }
            else
            {
                enum isValidMember = false;
            }
        }
        else
        {
            enum isValidMember = false;
        }
    }

    alias APIEvents = Filter!(isValidMember, derivedMembers);
}