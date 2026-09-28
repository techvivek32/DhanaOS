/// There is no `dart:io` on the web; the browser client's failures arrive as `ClientException`,
/// which `errors.dart` matches separately.
bool isIoTransportError(Object error) => false;
