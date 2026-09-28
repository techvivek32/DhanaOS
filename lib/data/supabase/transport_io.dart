import 'dart:io';

/// The `dart:io` transport family — `SocketException`, `HttpException`, `TlsException`.
bool isIoTransportError(Object error) => error is IOException;
