/// Items 13/14 (device side): server par jo checks hain (URL scheme,
/// dangerous file type) unhe **device par bhi** enforce karte hain, taaki
/// agar koi command server ko bypass karke ya purane server se aaye to
/// bhi `file://` navigate ya `.exe` write na ho. Yeh dispatcher
/// (`agent_connection.dart`) mein Android/Windows/Linux teeno ke liye
/// ek hi jagah lagta hai.
library;

const _dangerousExtensions = {
  '.exe', '.msi', '.msix', '.appx', '.bat', '.cmd', '.com', '.scr', '.pif',
  '.ps1', '.psm1', '.vbs', '.vbe', '.wsf', '.wsh', '.hta', '.js', '.jse',
  '.lnk', '.reg', '.cpl', '.msc', '.gadget', '.inf',
  '.sh', '.bash', '.zsh', '.run', '.bin', '.py', '.pl', '.rb',
  '.desktop', '.appimage', '.deb', '.rpm',
  '.apk', '.aab', '.dex',
  '.dll', '.so', '.dylib', '.sys',
  '.jar',
};

/// `true` agar `path` ki last file name dangerous extension par khatam
/// hoti hai. Case, trailing dots/spaces aur NTFS ADS (`a.txt:evil.exe`)
/// handle hote hain.
bool isDangerousFilePath(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
  for (final raw in name.split(':')) {
    final part = raw.replaceAll(RegExp(r'[. ]+$'), '');
    for (final ext in _dangerousExtensions) {
      if (part.endsWith(ext)) return true;
    }
  }
  return false;
}

/// `true` sirf valid `http`/`https` URL (host ke saath) ke liye.
bool isAllowedBrowserUrl(String? url) {
  if (url == null) return false;
  final trimmed = url.trim();
  if (trimmed.isEmpty || trimmed.length > 8192) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// App launcher identifier mein shell metacharacters/path tricks nahi
/// hone chahiye (native layer ek allowlist se bhi match karta hai, yeh
/// sirf pehli, sasti line of defence hai).
bool isPlausibleAppIdentifier(String? id) {
  if (id == null || id.isEmpty || id.length > 512) return false;
  return !RegExp(r'[\x00-\x1f;|&`$<>\n\r]').hasMatch(id);
}
