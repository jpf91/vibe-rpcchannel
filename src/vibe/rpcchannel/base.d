module vibe.rpcchannel.base;

import vibe.core.stream;
import vibe.core.sync;

import std.traits;
import std.range : ElementType;

import vibe.rpcchannel.protocol;

/*
 * 
 */
struct IgnoreUDA
{
}

/**
 * 
 */
enum ignoreRPC = IgnoreUDA.init;

/**
 * 
 */
class RPCException : Exception
{
    public
    {
        @safe pure nothrow this(string message, string file = __FILE__,
            size_t line = __LINE__, Throwable next = null)
        {
            super(message, file, line, next);
        }
    }
}

class DisconnectedException : RPCException
{
    public
    {
        @safe pure nothrow this(string message = "Connection disconnected",
            string file = __FILE__, size_t line = __LINE__, Throwable next = null)
        {
            super(message, file, line, next);
        }
    }
}

/*
 *
 */
void skipParameters(Stream stream, size_t num)
{
    // skip remaining params
    for (size_t i = 0; i < num; i++)
    {
        stream.deserializeJsonLine!void();
    }
}

/*
 *
 */
enum bool isEmittable2(T) = isArray!T && isDelegate!(ElementType!T)
        && (is(ReturnType!(ElementType!T) == bool) || is(ReturnType!(ElementType!T) == void));

/*
 * 
 */
enum bool isSpecialFunction(string name) = name == "startSession"
        || name == "__dtor" || (name.length >= 6 && name[0 .. 5] == "__ctor"
        || name == "toHash" || name == "toString");
