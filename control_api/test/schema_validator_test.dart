import 'package:control_api/validation/schema_validator.dart';
import 'package:test/test.dart';

Map<String, dynamic> _validTapEnvelope() => {
      'protocol_version': '1.0',
      'request_id': 'req_1',
      'api_key_id': 'key_1',
      'capability': 'input',
      'action': 'input.tap',
      'params': {'x': 100, 'y': 200},
    };

void main() {
  group('validateRawBody — malformed JSON / oversized (P0-04)', () {
    test('malformed JSON => INVALID_REQUEST, no crash', () {
      final result = validateRawBody('{not valid json', 15);
      expect(result.isValid, isFalse);
      expect(result.error!.kind, 'INVALID_REQUEST');
    });

    test('valid JSON but not an object (array) => INVALID_REQUEST', () {
      final result = validateRawBody('[1,2,3]', 7);
      expect(result.isValid, isFalse);
    });

    test('oversized body => PAYLOAD_TOO_LARGE, rejected before JSON parse', () {
      final result = validateRawBody('{}', maxRequestBodyBytes + 1);
      expect(result.isValid, isFalse);
      expect(result.error!.kind, 'PAYLOAD_TOO_LARGE');
    });

    test('valid envelope round-trips through validateRawBody', () {
      final envelope = _validTapEnvelope();
      final raw = '{"protocol_version":"1.0","request_id":"req_1",'
          '"api_key_id":"key_1","capability":"input","action":"input.tap",'
          '"params":{"x":100,"y":200}}';
      final result = validateRawBody(raw, raw.length);
      expect(result.isValid, isTrue);
      expect(result.envelope!['action'], envelope['action']);
    });
  });

  group('validateEnvelopeShape — required top-level fields (P0-04)', () {
    test('missing request_id => invalid', () {
      final e = _validTapEnvelope()..remove('request_id');
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('missing api_key_id => invalid', () {
      final e = _validTapEnvelope()..remove('api_key_id');
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('wrong type for request_id (number instead of string) => invalid, no crash', () {
      final e = _validTapEnvelope();
      e['request_id'] = 12345;
      final result = validateEnvelopeShape(e);
      expect(result.isValid, isFalse);
    });

    test('missing capability => invalid', () {
      final e = _validTapEnvelope()..remove('capability');
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('missing action => invalid', () {
      final e = _validTapEnvelope()..remove('action');
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('valid minimal envelope passes', () {
      expect(validateEnvelopeShape(_validTapEnvelope()).isValid, isTrue);
    });
  });

  group('validateEnvelopeShape — unknown/mismatched action (P0-04)', () {
    test('unsupported/unknown action => invalid', () {
      final e = _validTapEnvelope();
      e['action'] = 'teleport.now';
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('capability/action mismatch => invalid', () {
      final e = _validTapEnvelope();
      e['capability'] = 'screen'; // action is still input.tap
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });
  });

  group('validateEnvelopeShape — params schema (P0-04)', () {
    test('missing required param (input.tap needs x, y) => invalid', () {
      final e = _validTapEnvelope();
      e['params'] = {'x': 100}; // y missing
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('wrong type for required param (x as string) => invalid', () {
      final e = _validTapEnvelope();
      e['params'] = {'x': 'not-a-number', 'y': 200};
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('unknown param field is rejected by default', () {
      final e = _validTapEnvelope();
      e['params'] = {'x': 100, 'y': 200, 'unexpected_field': 'oops'};
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('params present but not an object => invalid', () {
      final e = _validTapEnvelope();
      e['params'] = 'oops';
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('requiredOneOf: files.read accepts "path"', () {
      final e = {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'files',
        'action': 'files.read',
        'params': {'path': '/tmp/x.txt'},
      };
      expect(validateEnvelopeShape(e).isValid, isTrue);
    });

    test('requiredOneOf: files.read accepts legacy "target_path"', () {
      final e = {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'files',
        'action': 'files.read',
        'params': {'target_path': '/tmp/x.txt'},
      };
      expect(validateEnvelopeShape(e).isValid, isTrue);
    });

    test('requiredOneOf: files.read rejects when neither given', () {
      final e = {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'files',
        'action': 'files.read',
        'params': <String, dynamic>{},
      };
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('enum validation: control.switch rejects invalid switch_type', () {
      final e = {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'control',
        'action': 'control.switch',
        'params': {'switch_type': 'not_a_real_type', 'value': 'x'},
      };
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('string maxLength enforced (input.type_text)', () {
      final e = {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'input',
        'action': 'input.type_text',
        'params': {'text': List.filled(10001, 'a').join()},
      };
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('action with empty schema (e.g. screen.capture) allows empty params', () {
      final e = {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'screen',
        'action': 'screen.capture',
        'params': <String, dynamic>{},
      };
      expect(validateEnvelopeShape(e).isValid, isTrue);
    });

    Map<String, dynamic> msgEnvelope(String action, Map<String, dynamic> params) => {
          'protocol_version': '1.0',
          'request_id': 'r1',
          'api_key_id': 'k1',
          'capability': 'background',
          'action': action,
          'params': params,
        };

    test('messaging.get_event: defined optional params ok, unknown field rejected (P1-06)', () {
      expect(validateEnvelopeShape(msgEnvelope('messaging.get_event',
          {'limit': 10, 'since_ms': 0, 'package': 'com.whatsapp'})).isValid, isTrue);
      expect(validateEnvelopeShape(msgEnvelope('messaging.get_event',
          {'anything_goes_here': 123})).isValid, isFalse);
      expect(validateEnvelopeShape(msgEnvelope('messaging.get_event',
          {'limit': 500})).isValid, isFalse);
    });

    test('messaging.prepare_reply requires event_id + text, text <= 1000 chars (P1-06)', () {
      expect(validateEnvelopeShape(msgEnvelope('messaging.prepare_reply',
          {'event_id': 'msg_1', 'text': 'hello'})).isValid, isTrue);
      expect(validateEnvelopeShape(msgEnvelope('messaging.prepare_reply',
          {'event_id': 'msg_1'})).isValid, isFalse);
      expect(validateEnvelopeShape(msgEnvelope('messaging.prepare_reply',
          {'event_id': 'msg_1', 'text': List.filled(1001, 'a').join()})).isValid, isFalse);
    });

    test('messaging.send_reply requires draft_id only (no free text bypass) (P1-06)', () {
      expect(validateEnvelopeShape(msgEnvelope('messaging.send_reply',
          {'draft_id': 'draft_1'})).isValid, isTrue);
      expect(validateEnvelopeShape(msgEnvelope('messaging.send_reply', {})).isValid, isFalse);
      expect(validateEnvelopeShape(msgEnvelope('messaging.send_reply',
          {'draft_id': 'draft_1', 'text': 'sneaky override'})).isValid, isFalse);
    });
  });

  group('validateEnvelopeShape — payload & timeout_ms bounds (P0-04)', () {
    test('payload wrong type (number instead of base64 string) => invalid', () {
      final e = _validTapEnvelope();
      e['payload'] = 12345;
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('payload null is allowed', () {
      final e = _validTapEnvelope();
      e['payload'] = null;
      expect(validateEnvelopeShape(e).isValid, isTrue);
    });

    test('timeout_ms within bounds is allowed', () {
      final e = _validTapEnvelope();
      e['timeout_ms'] = 8000;
      expect(validateEnvelopeShape(e).isValid, isTrue);
    });

    test('timeout_ms above max is rejected', () {
      final e = _validTapEnvelope();
      e['timeout_ms'] = maxTimeoutMs + 1;
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('timeout_ms of zero/negative is rejected', () {
      final e = _validTapEnvelope();
      e['timeout_ms'] = 0;
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });

    test('timeout_ms wrong type is rejected', () {
      final e = _validTapEnvelope();
      e['timeout_ms'] = '8000';
      expect(validateEnvelopeShape(e).isValid, isFalse);
    });
  });
}
