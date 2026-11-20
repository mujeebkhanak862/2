/// P0-07 — connector registry. Naya provider add karna: ek class
/// `ConnectorProvider` implement karo, yahan register karo — routes
/// (`routes/connectors.dart`) aur poora OAuth/encryption/refresh flow
/// generic hai, dobara likhne ki zaroorat nahi.
library;

import 'connector_provider.dart';
import 'dropbox_provider.dart';
import 'google_drive_provider.dart';

final Map<String, ConnectorProvider> _registry = {
  'google_drive': GoogleDriveConnectorProvider(),
  'dropbox': DropboxConnectorProvider(),
};

ConnectorProvider? connectorProviderByName(String name) => _registry[name];

List<ConnectorProvider> allConnectorProviders() => _registry.values.toList();

/// Sirf tests ke liye — ek fake provider ko registry mein temporarily
/// daalne ke liye (real Google servers ko hit kiye bina poora
/// auth/callback/disconnect flow test karne ke liye).
void registerConnectorProviderForTesting(ConnectorProvider provider) {
  _registry[provider.name] = provider;
}
