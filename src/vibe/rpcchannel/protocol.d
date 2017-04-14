/**
 * Low level wire protocol for RPC.
 */
module vibe.rpcchannel.protocol;

import std.exception : enforceEx;
import vibe.data.json;
import vibe.core.stream;
import vibe.rpcchannel.base;

/*
 * Problem : vibe.d does not really support JSON deserialization from a range
 * Solution : Always read & buffer a line and use line terminators after every
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

/**
 * Type of message sent to server.
 */
enum RequestType
{
    call, /// call a function
    disconnect /// disconnect
}

/**
 * Message sent to server to call a function.
 */
struct CallMessage
{
    uint id; /// request id
    string target; /// function target name
    string mangle; /// function mangle for overloading
    uint parameters; /// number of parameters following this message
}

/**
 * Type of message sent to client.
 */
enum ResponseType
{
    disconnect, /// Disconnect the session
    error, /// An error occured
    result, /// A function result is returned
    event /// A event occured
}

/**
 * If an error is being send, type of error.
 */
enum ErrorType
{
    notImplemented, /// calling an unimplemented endpoint
    parameterMismatch, /// invalid number of parameters or parser error
    internalError /// called method threw an Exception
}

/**
 * Message sent to client as response to a call if an error occured.
 */
struct ErrorMessage
{
    uint id;  /// The request id repeated
    ErrorType type;  /// Type of error

    @optional string message; /// In debug mode only
    @optional string file; /// In debug mode only
    @optional uint line; /// In debug mode only
}

/**
 * Message sent to client as response to a call if call was sucessfull.
 */
struct ResultMessage
{
    uint id; /// The request id repeated
    bool hasResult; /// Whether there's a result value after this message
}

/**
 * Message sent to client if an event occurs.
 */
struct EventMessage
{
    string target; /// Name of the event
    uint parameters; /// Number of parameters following this message
}

/**
 * Read one line from stream and deserialize the json value.
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

/**
 * Serialize the json value and write as one line to stream.
 */
void serializeToJsonLine(T)(OutputStream stream, T value)
{
    auto str = serializeToJsonString(value);
    stream.write(str);
    stream.write("\n");
}

/**
 * Skip num objects on stream.
 */
void skipParameters(Stream stream, size_t num)
{
    // skip remaining params
    for (size_t i = 0; i < num; i++)
    {
        stream.deserializeJsonLine!void();
    }
}