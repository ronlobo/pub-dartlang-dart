// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test/test.dart';

import 'package:pub_dartlang_org/frontend/handlers/redirects.dart';

import '../../shared/handlers_test_utils.dart';

import '_utils.dart';

void main() {
  group('redirects', () {
    test('dartdocs.org redirect', () async {
      expectRedirectResponse(
        await issueGetUri(
            Uri.parse('https://dartdocs.org/documentation/pkg/latest/')),
        'https://pub.dartlang.org/documentation/pkg/latest/',
      );
    });

    test('www.dartdocs.org redirect', () async {
      expectRedirectResponse(
        await issueGetUri(
            Uri.parse('https://www.dartdocs.org/documentation/pkg/latest/')),
        'https://pub.dartlang.org/documentation/pkg/latest/',
      );
    });

    tScopedTest('/doc', () async {
      for (var path in redirectPaths.keys) {
        final redirectUrl =
            'https://www.dartlang.org/tools/pub/${redirectPaths[path]}';
        expectRedirectResponse(await issueGet(path), redirectUrl);
      }
    });

    // making sure /doc does not catches /documentation request
    tScopedTest('/documentation', () async {
      expectRedirectResponse(await issueGet('/documentation/pana/'),
          '/documentation/pana/latest/');
    });

    tScopedTest('/flutter/plugins', () async {
      expectRedirectResponse(
          await issueGet('/flutter/plugins'), '/flutter/packages');
    });

    tScopedTest('/search?q=foobar', () async {
      expectRedirectResponse(await issueGet('/search?q=foobar'),
          'https://pub.dartlang.org/packages?q=foobar');
    });

    tScopedTest('/search?q=foobar&page=2', () async {
      expectRedirectResponse(await issueGet('/search?q=foobar&page=2'),
          'https://pub.dartlang.org/packages?q=foobar&page=2');
    });

    tScopedTest('/server', () async {
      expectRedirectResponse(await issueGet('/server'), '/');
    });

    tScopedTest('/server/packages with parameters', () async {
      expectRedirectResponse(
          await issueGet('/server/packages?sort=top'), '/packages?sort=top');
    });

    tScopedTest('/server/packages', () async {
      expectRedirectResponse(await issueGet('/server/packages'), '/packages');
    });

    tScopedTest('/packages/flutter - redirect', () async {
      expectRedirectResponse(
        await issueGet('/packages/flutter'),
        'https://pub.dartlang.org/flutter',
      );
    });

    tScopedTest('/packages/flutter/versions/* - redirect', () async {
      expectRedirectResponse(
        await issueGet('/packages/flutter/versions/0.20'),
        'https://pub.dartlang.org/flutter',
      );
    });
  });
}
