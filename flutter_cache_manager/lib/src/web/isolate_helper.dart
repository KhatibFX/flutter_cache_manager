import 'dart:isolate';

/// generic method to handle isolate creation and error handling
/// Note that isolates and their methods must be run from a top level function, or class static functions.
Future<T> initializeGenericIsolate<T>(
    {required Future<void> Function(List<dynamic> args) initializeInternalFunction,
    required List<dynamic> params}) async {
  // create the port to receive data from
  final resultPort = ReceivePort();
  // Adding errorsAreFatal makes sure that the main isolates receives a message
  // that something has gone wrong
  try {
    await Isolate.spawn(
      initializeGenericIsolateInternal,
      [resultPort.sendPort, initializeInternalFunction, params],
      errorsAreFatal: true,
      onExit: resultPort.sendPort,
      onError: resultPort.sendPort,
    );
  } on Object {
    // check if sending the entrypoint to the new isolate failed.
    // If it did, the result port won’t get any message, and needs to be closed
    resultPort.close();
    //TODO throw error
    rethrow;
  }

  final response = await resultPort.first;

  if (response == null) {
    // this means the isolate exited without sending any results
    // TODO throw error
    throw Exception('Isolate exited without sending any results');
  } else if (response is List) {
    // if the response is a list, this means an uncaught error occurred
    final errorAsString = response[0];
    final stackTraceAsString = response[1];
    dynamic error = _getErrorFromString(errorAsString);
    throw error;
  } else {
    // if the response is not a list, this means the isolate exited successfully
    return response as T;
  }
}

// TODO handle possible throwable errors
_getErrorFromString(errorAsString) {
  switch (errorAsString) {
    case "Instance of 'SocketException'":
      return Exception("Socket Exception");
    case "Instance of 'HttpException'":
      return Exception("Http Exception");
    case "Instance of 'FormatException'":
      return Exception("Format Exception");
    default:
      return Exception(errorAsString);
  }
}

/// generic method to handle redundant logic inside isolates
Future<void> initializeGenericIsolateInternal(List<dynamic> args) async {
  SendPort resultPort = args[0];

  dynamic result = await args[1](args[2]);
  Isolate.exit(resultPort, result);
}
