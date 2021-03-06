// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:args/args.dart';
import 'package:gcloud/db.dart';
import 'package:pool/pool.dart';

import 'package:pub_dartlang_org/account/backend.dart';
import 'package:pub_dartlang_org/account/models.dart';
import 'package:pub_dartlang_org/frontend/models.dart';
import 'package:pub_dartlang_org/frontend/service_utils.dart';

final _argParser = new ArgParser()
  ..addOption('concurrency',
      abbr: 'c', defaultsTo: '1', help: 'Number of concurrent processing.')
  ..addOption('package', abbr: 'p', help: 'The package to backfill.')
  ..addFlag('help', abbr: 'h', defaultsTo: false, help: 'Show help.');

final _emailInProgress = <String, Completer>{};
final _emailToUser = <String, User>{};
final _userFirstUsed = <String, DateTime>{};

Future main(List<String> args) async {
  final argv = _argParser.parse(args);
  if (argv['help'] as bool == true) {
    print('Usage: dart backfull_user_ids.dart');
    print(
        'Ensures a User entity exists for each email used in PackageVersion.uploaderEmail and Package.uploaderEmails.');
    print(
        'Ensures that Package.uploaders is a subset of userIds for emails in Package.uploaderEmails.');
    print(
        'Ensures that PackageVersion.uploader is the userId of PackageVersion.uploaderEmail.');
    print(_argParser.usage);
    return;
  }

  final concurrency = int.parse(argv['concurrency'] as String);
  final package = argv['package'] as String;
  await withProdServices(() async {
    registerAccountBackend(AccountBackend(dbService));

    if (package != null) {
      await _backfillPackage(package);
    } else {
      final pool = Pool(concurrency);
      final futures = <Future>[];

      await for (Package p in dbService.query<Package>().run()) {
        final f = pool.withResource(() => _backfillPackage(p.name));
        futures.add(f);
      }

      await Future.wait(futures);
      await pool.close();
    }

    for (User user in _emailToUser.values) {
      final created = _userFirstUsed[user.userId];
      if (created != null && user.created.isAfter(created)) {
        await _updateUserCreatedTime(user, created);
      }
    }

    // Delete users with non-lowercase e-mails.
    await for (User user in dbService.query<User>().run()) {
      if (user.email != user.email.toLowerCase()) {
        print('Deleting: ${user.email} ${user.userId} ${user.oauthUserId}');
        final deletes = <Key>[user.key];
        if (user.oauthUserId != null) {
          deletes.add(
              dbService.emptyKey.append(OAuthUserID, id: user.oauthUserId));
        }
        await dbService.commit(deletes: deletes);
      }
    }
  });
}

Future _backfillPackage(String package) async {
  print('Processing package: $package');
  final pkgKey = dbService.emptyKey.append(Package, id: package);

  final versionQuery = dbService.query<PackageVersion>(ancestorKey: pkgKey);
  await for (PackageVersion pv in versionQuery.run()) {
    final user = await _lookupUserByEmail(pv.uploaderEmail);
    _updateFirstUse(user, pv.created);

    final doUpdateEmail = pv.uploaderEmail != pv.uploaderEmail.toLowerCase();
    if (pv.uploader == null || doUpdateEmail) {
      await dbService.withTransaction((tx) async {
        final version = (await tx.lookup<PackageVersion>([pv.key])).single;
        if (version.uploader != null && !doUpdateEmail) {
          throw AssertionError(
              'upload updated before transaction: ${pv.package} ${pv.version}');
        }
        version.uploader = user.userId;
        version.uploaderEmail = version.uploaderEmail.toLowerCase();
        tx.queueMutations(inserts: [version]);
        await tx.commit();
      });
    } else if (pv.uploader != user.userId && !doUpdateEmail) {
      throw AssertionError(
          'upload missmatch in ${pv.package} ${pv.version}: ${pv.uploaderEmail} '
          'maps to ${user.userId} but already contains ${pv.uploader}');
    }
  }

  await dbService.withTransaction((tx) async {
    final p = (await dbService.lookup<Package>([pkgKey])).single;
    final uploaders = Set<String>();
    p.uploaderEmails =
        p.uploaderEmails.map((s) => s.toLowerCase()).toSet().toList();
    for (String email in p.uploaderEmails) {
      final user = await _lookupUserByEmail(email);
      uploaders.add(user.userId);
    }
    p.uploaders = uploaders.toList();
    if (p.uploaders.length != p.uploaderEmails.length ||
        p.uploaders.any((s) => s == null)) {
      throw AssertionError(
          'Uploaders missmatch in ${p.name}: ${p.uploaderEmails} / ${p.uploaders}');
    }
    tx.queueMutations(inserts: [p]);
    await tx.commit();
  });
}

Future _updateUserCreatedTime(User user, DateTime created) async {
  print('Updating created time for user (${user.userId} / ${user.email})');
  await dbService.withTransaction((tx) async {
    final u = (await tx.lookup<User>([user.key])).single;
    if (u.created.isAfter(created)) {
      u.created = created;
      tx.queueMutations(inserts: [u]);
      await tx.commit();
    } else {
      await tx.rollback();
    }
  });
}

Future<User> _lookupUserByEmail(String email) async {
  email = email.toLowerCase();
  if (_emailInProgress.containsKey(email)) {
    await _emailInProgress[email].future;
  }
  if (_emailToUser.containsKey(email)) {
    return _emailToUser[email];
  }
  _emailInProgress[email] = Completer();
  final user = await accountBackend.lookupOrCreateUserByEmail(email);
  _emailToUser[email] = user;
  _emailInProgress.remove(email).complete();
  return user;
}

void _updateFirstUse(User user, DateTime time) {
  final old = _userFirstUsed[user.userId];
  if (old == null || old.isAfter(time)) {
    _userFirstUsed[user.userId] = time;
  }
}
