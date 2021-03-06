import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/browser_client.dart';
import 'package:http/http.dart' show Response, Request;
import 'http_status_codes.dart';
import 'utils.dart';

class HttpClientInMemoryBackendService extends BrowserClient {
  InMemoryBackendConfigArgs _config;
  Map<String, dynamic> _db = {};
  CreateDb _seedData;

  HttpClientInMemoryBackendService(CreateDb seedData,
      {InMemoryBackendConfigArgs config}) {
    _seedData = seedData;
    _resetDb();
    final location = new Location('./');
    _config = new InMemoryBackendConfig(
        delay: config?.delay,
        delete404: config?.delete404,
        host: config?.host ?? location.host,
        rootPath: config?.rootPath ?? location.pathname);
  }

  Future<Response> get(dynamic url, {Map<String, String> headers}) =>
      _handleRequest(_createRequest('GET', url, headers));

  Future<Response> post(dynamic url,
          {Map<String, String> headers,
          dynamic body,
          Encoding encoding}) async =>
      _handleRequest(_createRequest('POST', url, headers, body, encoding));

  Future<Response> put(dynamic url,
          {Map<String, String> headers, dynamic body, Encoding encoding}) =>
      _handleRequest(_createRequest('PUT', url, headers, body, encoding));

  Future<Response> delete(dynamic url, {Map<String, String> headers}) =>
      _handleRequest(_createRequest('DELETE', url, headers));

  Request _createRequest(String method, url, Map<String, String> headers,
      [body, Encoding encoding]) {
    if (url is String) url = Uri.parse(url);
    var request = new Request(method, url);

    if (headers != null) request.headers.addAll(headers);
    if (encoding != null) request.encoding = encoding;
    if (body != null) {
      if (body is String) {
        request.body = body;
      } else if (body is List) {
        request.bodyBytes = body;
      } else if (body is Map) {
        request.bodyFields = body;
      } else {
        throw new ArgumentError('Invalid request body "$body".');
      }
    }

    return request;
  }

  Future<Response> _handleRequest(Request req) async {
    final data = _parseUrl(req.url.toString());

    final reqInfo = new RequestInfo(
        req,
        data.base,
        new Collection(data.collectionName, this._db[data.collectionName]),
        {'Content-Type': 'application/json'},
        _parseId(data.id),
        data.resourceUrl);

    Response response;

    switch (req.method.toLowerCase()) {
      case 'get':
        response = _get(reqInfo);
        break;
      case 'post':
        response = _post(reqInfo);
        break;
      case 'put':
        response = _put(reqInfo);
        break;
      case 'delete':
        response = _delete(reqInfo);
        break;
    }

    final duration = new Duration(milliseconds: _config.delay);
    return await new Future.delayed(duration, () => response);
  }

  Response _get(RequestInfo req) {
    final data =
        req.hasId ? _findById(req.collection, req.id) : req.collection.data;
    if (data == null) {
      return _createErrorResponse(STATUS['NOT_FOUND'],
          '"${req.collection}" with id="${req.id}" not found');
    }
    final body = JSON.encode({'data': data});
    return new Response(body, STATUS['OK'], headers: req.headers);
  }

  Response _post(RequestInfo reqInfo) {
    Map item = JSON.decode(reqInfo.req.body);
    if (!item.containsKey('id')) {
      item['id'] = reqInfo.id ?? _genId(reqInfo.collection);
    }
    // ignore the request id, if any. Alternatively,
    // could reject request if id differs from item.id

    int index = _indexOf(reqInfo.collection, item['id']);

    if (index > -1) {
      reqInfo.collection.data[index] = item;
      return new Response(null, STATUS['NO_CONTENT'], headers: reqInfo.headers);
    }

    reqInfo.collection.data.add(item);
    reqInfo.headers['Location'] = '${reqInfo.resourceUrl}/${item['id']}';
    final body = JSON.encode({'data': item});
    return new Response(body, STATUS['CREATED'], headers: reqInfo.headers);
  }

  Response _put(RequestInfo reqInfo) {
    Map item = JSON.decode(reqInfo.req.body);
    if (reqInfo.id == null) {
      return _createErrorResponse(
          STATUS['NOT_FOUND'], 'Missing "${reqInfo.collection}" id');
    }
    if (reqInfo.id != item['id']) {
      return _createErrorResponse(STATUS['BAD_REQUEST'],
          '"${reqInfo.collection}" id does not match item.id');
    }

    int index = _indexOf(reqInfo.collection, item['id']);
    if (index > -1) {
      reqInfo.collection.data[index] = item;
      return new Response('', STATUS['NO_CONTENT'], headers: reqInfo.headers);
    }

    reqInfo.collection.data.add(item);
    final body = JSON.encode({'data': item});
    return new Response(body, STATUS['CREATED'], headers: reqInfo.headers);
  }

  Response _delete(RequestInfo reqInfo) {
    if (reqInfo.id == null) {
      return _createErrorResponse(
          STATUS['NOT_FOUND'], 'Missing "${reqInfo.collection}" id');
    }

    int index = _indexOf(reqInfo.collection, reqInfo.id);
    bool exists = index > -1;
    if (exists) {
      reqInfo.collection.data.removeAt(index);
    }

    int status = (exists || !_config.delete404)
        ? STATUS['NO_CONTENT']
        : STATUS['NOT_FOUND'];
    return new Response('', status, headers: reqInfo.headers);
  }

  int _genId(Collection collection) {
    int maxId = 0;
    collection.data.reduce((prev, item) {
      math.max(maxId, (item['id'] is num) ? item['id'] : maxId);
    });
    return maxId + 1;
  }

  int _indexOf(Collection collection, dynamic id) {
    for (var i = 0; i < collection.data.length; i++) {
      if (collection.data[i]['id'] == id) {
        return i;
      }
    }
    return -1;
  }

  dynamic _findById(Collection collection, dynamic id) {
    try {
      return collection.data.firstWhere(
          (Map item) => item.containsKey('id') ? item['id'] == id : false);
    } catch (e) {
      return null;
    }
  }

  /// tries to parse id as integer; returns input id if not an integer.
  dynamic _parseId(String id) {
    if (id == null) return null;
    try {
      return int.parse(id);
    } catch (e) {
      return id;
    }
  }

  Response _createErrorResponse(int status, String message) {
    final body = JSON.encode({"error": '$message'});
    final headers = {"Content-Type": "application/json"};
    return new Response(body, status, headers: headers);
  }

  ParsedURL _parseUrl(String url) {
    final location = new Location(url);
    int drop = _config.rootPath.length;
    String urlRoot = '';
    if (location.host != _config.host) {
      // url for a server on a different host!
      // assume it's collection is actually here too.
      drop = 1; // the leading slash
      urlRoot = '${location.protocol}//${location.host}/';
    }

    String path = location.pathname.substring(drop);
    final splitedPath = path.split('/');
    final base = splitedPath[0];
    final collectionName = splitedPath[1].split('.')[0];
    final id = splitedPath.length > 2 ? splitedPath[2] : null;
    final resourceUrl = '$urlRoot$base/$collectionName/';
    return new ParsedURL(base, collectionName, id, resourceUrl);
  }

  void _resetDb() {
    _db = _seedData();
  }
}
