module vibe.rpcchannel.protocol;

import std.exception : enforceEx;
import vibe.data.json;
import vibe.core.stream;
import vibe.rpcchannel.base;

/*
 * Problem: vibe.d does not really support JSON deserialization from a range
 * Solution: Always read & buffer a line and use line terminators after every
 * JSON entity.
 * 
 * Request protocol:
 * 
 * RequestType   
 *               |----=call-->CallMessage-->parameters*any
 * --------------|
 *               |----=disconnect
 * 
 * Reponse protocol:
 * 
 * ResponseType  |---=error-->ErrorMessage
 * --------------|
 *               |---=result->ResultMessage-->hasResult?any:none
 *               |
 *               |---=event-->EventMessage-->parameters*any
 *               |
 *               |---=disconnect
 */

enum RequestType
{
    call, // call a function
    disconnect // disconnect
}

struct CallMessage
{
    uint id;
    string target;
    string mangle;
    uint parameters;
}

enum ResponseType
{
    disconnect, // Disconnect the session
    error, // An error occured
    result, // A function result is returned
    event // A event occured
}

enum ErrorType
{
    notImplemented, // calling an unimplemented endpoint
    parameterMismatch, // invalid number of parameters or parser error
    internalError // called method threw an Exception
}

struct ErrorMessage
{
    uint id;
    ErrorType type;

    @optional string message;
    @optional string file;
    @optional uint line;
}

struct ResultMessage
{
    uint id;
    bool hasResult;
}

struct EventMessage
{
    string target;
    uint parameters;
}

/*
 * 
 */
T deserializeJsonLine(T)(InputStream stream)
{
    import vibe.stream.operations;

    // TODO: Avoid GC
    auto line = cast(string) stream.readLine(size_t.max, "\n");

    enforceEx!RPCException(line.length != 0);

    static if (!is(T == void))
        return deserializeJson!T(line);
}

/*
 * 
 */
void serializeToJsonLine(T)(OutputStream stream, T value)
{
    auto str = serializeToJsonString(value);
    stream.write(str);
    stream.write("\n");
}