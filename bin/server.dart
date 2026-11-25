import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

//trasforma una password in hash
String hashPassword(String password) =>
    sha256.convert(utf8.encode(password)).toString();

//crea un token per l'accesso
String newToken() {
  final r = Random.secure();
  return List.generate(
      32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}

//legge il token dall'header Authorization (o da ?token=...)
String? readToken(Request req) {
  final header = req.headers['authorization'];
  if (header != null && header.startsWith('Bearer ')) {
    return header.substring(7);
  }
  return req.url.queryParameters['token'];
}

//scorciatoia per rispondere con un JSON e un codice
Response jsonResponse(Object body, [int status = 200]) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

//toglie dalla candidatura i campi interni (il nome del file sul disco)
Map<String, dynamic> publicApplication(Map<String, dynamic> a) => {
  'id': a['id'],
  'jobId': a['jobId'],
  'firstName': a['firstName'],
  'lastName': a['lastName'],
  'email': a['email'],
  'cvName': a['cvName'],
};

//tipo di file da dichiarare quando l'azienda apre il curriculum
String contentTypeFor(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  return 'application/octet-stream';
}

Future<void> main() async {
  // final List<Map<String, dynamic>> jobs = []; //ogni annuncio e una map, una copia chiave-valore come il json {'id'=1}
  // final List<Map<String, dynamic>> companies = [];
  // final Map<String, String> sessions = {}; // sarebbe il token
  // final List<Map<String, dynamic>> applications = [];
  final dataFile = File('data/db.json');
  Directory('data/uploads').createSync(recursive: true); //cartella dei curriculum
  final List<Map<String, dynamic>> jobs = [];
  final List<Map<String, dynamic>> companies = [];
  final List<Map<String, dynamic>> applications = [];
  final Map<String, String> sessions = {};

  //all'avvio rilegge i dati salvati, se il file esiste
  if (dataFile.existsSync()) {
    final saved =
    jsonDecode(dataFile.readAsStringSync()) as Map<String, dynamic>;
    jobs.addAll((saved['jobs'] as List).cast<Map<String, dynamic>>());
    companies.addAll((saved['companies'] as List).cast<Map<String, dynamic>>());
    applications
        .addAll((saved['applications'] as List).cast<Map<String, dynamic>>());
    sessions.addAll((saved['sessions'] as Map).cast<String, String>());
  }

  //scrive tutto su file: da chiamare dopo ogni modifica
  void saveDb() {
    dataFile.writeAsStringSync(jsonEncode({
      'jobs': jobs,
      'companies': companies,
      'applications': applications,
      'sessions': sessions,
    }));
  }

  //restituisce l'id dell'azienda loggata
  String? authCompanyId(Request req) {
    final token = readToken(req);
    return token == null ? null : sessions[token];
  }

  final router = Router();

  router.get('/ping', (Request req) {
    return Response.ok(
      jsonEncode({'ok': true}),
      headers: {'content-type': 'application/json'},
    );
  });

  router.get('/jobs', (Request req) {
    return Response.ok(
      jsonEncode(jobs),
      headers: {'content-type': 'application/json'},
    );
  });

 //questo e per aggiungere annunci
  router.post('/jobs', (Request req) async {
    final companyId = authCompanyId(req);
    if (companyId == null) {
      return jsonResponse({'error': 'Non autorizzato'}, 401);
    }

    final dati = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final title = dati['title'];
    final description = dati['description'];

    if (title is! String || title.trim().isEmpty) {
      return jsonResponse({'error': 'Titolo mancante'}, 400);
    }
    if (description is! String || description.trim().isEmpty) {
      return jsonResponse({'error': 'Descrizione mancante'}, 400);
    }

    final company = companies.firstWhere((c) => c['id'] == companyId);
    final job = {
      'id': '${jobs.length + 1}',
      'companyId': companyId,
      'companyName': company['name'],
      'title': title.trim(),
      'description': description.trim(),
    };
    jobs.add(job);
    saveDb();

    return jsonResponse(job, 201);
  });

  //dettaglio di un annuncio (pubblico)
  router.get('/jobs/<id>', (Request req, String id) {
    final trovati = jobs.where((j) => j['id'] == id);
    if (trovati.isEmpty) {
      return jsonResponse({'error': 'Annuncio non trovato'}, 404);
    }
    return jsonResponse(trovati.first);
  });

  //annunci dell'azienda loggata
  router.get('/my/jobs', (Request req) {
    final companyId = authCompanyId(req);
    if (companyId == null) {
      return jsonResponse({'error': 'Non autorizzato'}, 401);
    }
    return jsonResponse(
        jobs.where((j) => j['companyId'] == companyId).toList());
  });

  //logout: cancella il token dalle sessioni
  router.post('/logout', (Request req) {
    final token = readToken(req);
    if (token != null) {
      sessions.remove(token);
      saveDb();
    }
    return jsonResponse({'ok': true});
  });

  //R6: il candidato (senza login) invia la candidatura
  router.post('/jobs/<id>/applications', (Request req, String id) async {
    if (!jobs.any((j) => j['id'] == id)) {
      return jsonResponse({'error': 'Annuncio non trovato'}, 404);
    }

    final dati = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final firstName = dati['firstName'];
    final lastName = dati['lastName'];
    final email = dati['email'];
    final cvName = dati['cvName'];
    final cvBase64 = dati['cvBase64'];

    if (firstName is! String || firstName.trim().isEmpty) {
      return jsonResponse({'error': 'Il nome è obbligatorio'}, 400);
    }
    if (lastName is! String || lastName.trim().isEmpty) {
      return jsonResponse({'error': 'Il cognome è obbligatorio'}, 400);
    }
    if (email is! String || email.trim().isEmpty || !email.contains('@')) {
      return jsonResponse({'error': 'Inserisci un\'email valida'}, 400);
    }
    if (cvName is! String || cvName.isEmpty ||
        cvBase64 is! String || cvBase64.isEmpty) {
      return jsonResponse({'error': 'Il curriculum è obbligatorio'}, 400);
    }

    List<int> bytes;
    try {
      bytes = base64Decode(cvBase64);
    } catch (_) {
      return jsonResponse({'error': 'Curriculum non valido'}, 400);
    }

    final appId = '${applications.length + 1}';
    final safeName = cvName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final storedName = '${appId}_$safeName';
    File('data/uploads/$storedName').writeAsBytesSync(bytes);

    final application = {
      'id': appId,
      'jobId': id,
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      'email': email.trim(),
      'cvName': cvName,
      'cvFile': storedName,
    };
    applications.add(application);
    saveDb();

    return jsonResponse(publicApplication(application), 201);
  });

  //R7: l'azienda vede le candidature di un suo annuncio
  router.get('/my/jobs/<id>/applications', (Request req, String id) {
    final companyId = authCompanyId(req);
    if (companyId == null) {
      return jsonResponse({'error': 'Non autorizzato'}, 401);
    }
    if (!jobs.any((j) => j['id'] == id && j['companyId'] == companyId)) {
      return jsonResponse({'error': 'Annuncio non trovato'}, 404);
    }
    return jsonResponse(applications
        .where((a) => a['jobId'] == id)
        .map(publicApplication)
        .toList());
  });

  //R7: l'azienda apre il curriculum di una candidatura
  router.get('/applications/<id>/cv', (Request req, String id) {
    final companyId = authCompanyId(req);
    if (companyId == null) {
      return jsonResponse({'error': 'Non autorizzato'}, 401);
    }

    final trovate = applications.where((a) => a['id'] == id);
    if (trovate.isEmpty) {
      return jsonResponse({'error': 'Candidatura non trovata'}, 404);
    }
    final application = trovate.first;

    //solo l'azienda proprietaria dell'annuncio può aprire il curriculum
    if (!jobs.any((j) =>
    j['id'] == application['jobId'] && j['companyId'] == companyId)) {
      return jsonResponse({'error': 'Non autorizzato'}, 403);
    }

    final file = File('data/uploads/${application['cvFile']}');
    if (!file.existsSync()) {
      return jsonResponse({'error': 'File non trovato'}, 404);
    }

    final cvName = application['cvName'] as String;
    return Response.ok(
      file.readAsBytesSync(),
      headers: {
        'content-type': contentTypeFor(cvName),
        'content-disposition': 'inline; filename="$cvName"',
      },
    );
  });

  router.post('/register', (Request req) async {
    final dati = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final name = dati['name'];
    final email = dati['email'];
    final password = dati['password'];

    if (name is! String || name.trim().isEmpty) {
      return Response(400,
          body: jsonEncode({'error': 'Il nome è obbligatorio'}),
          headers: {'content-type': 'application/json'});
    }

    if (email is! String || email.trim().isEmpty || !email.contains('@')) {
      return Response(400,
          body: jsonEncode({'error': 'Inserisci un\'email valida'}),
          headers: {'content-type': 'application/json'});
    }

    if (password is! String || password.length < 6) {
      return Response(400,
          body: jsonEncode({'error': 'La password deve essere lunga almeno 6 caratteri'}),
          headers: {'content-type': 'application/json'});
    }

    if (companies.any((c) => c['email'] == email.trim().toLowerCase())) {
      return Response(409,
          body: jsonEncode({'error': 'Email già registrata'}),
          headers: {'content-type': 'application/json'});
    }

    final company = {
      'id': '${companies.length + 1}',
      'name': name.trim(),
      'email':email.trim().toLowerCase(),
      'passwordHash':hashPassword(password)
    };
    companies.add(company);
    saveDb();

    return Response(201,
        body: jsonEncode({
          'id':company['id'],
          'name':company['name'],
          'email':company['email'],
        }),
        headers: {'content-type': 'application/json'});
  });

  router.post('/login', (Request req) async {
    final dati = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final email = dati['email'];
    final password = dati['password'];

    if (email is! String || password is! String) {
      return Response(400,
          body: jsonEncode({'error': 'Inserisci email e password'}),
          headers: {'content-type': 'application/json'});
    }

    final trovate = companies.where((c) => c['email'] == email.trim().toLowerCase() && c['passwordHash'] == hashPassword(password));

    if (trovate.isEmpty) {
      return Response(401,
      body: jsonEncode({'error': 'Credenziali non valide'}),
      headers: {'content-type': 'application/json'});
    }

    final company = trovate.first;
    final token = newToken();
    sessions[token] = company['id'] as String;
    saveDb();

    return Response.ok(
      jsonEncode({
        'token': token,
        'company': {'id': company['id'], 'name': company['name']},
      }),
      headers: {'content-type': 'application/json'},
    );

  });

  final server = await io.serve(router.call, InternetAddress.anyIPv4, 8080);
  print('Server in ascolto sulla porta ${server.port}');
}

/*
Router() è l’elenco degli endpoint. Ogni router.get(...) dice:
 “quando arriva una GET a questo indirizzo, esegui questa funzione”.
La funzione riceve la richiesta (Request) e restituisce una risposta (Response).
Response.ok(...) risponde con codice 200 e il testo che gli passi, qui
un JSON creato con jsonEncode. L’header dice al client che il contenuto è JSON.
io.serve(...) avvia il server sulla porta 8080. anyIPv4 lo rende raggiungibile
 anche dall’iPhone, non solo dal Mac.
 */
