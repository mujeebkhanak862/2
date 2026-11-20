// contacts_manager.h
#ifndef DEVICE_AGENT_CONTACTS_MANAGER_H_
#define DEVICE_AGENT_CONTACTS_MANAGER_H_

#include <flutter/flutter_engine.h>

// Native side of `ChannelNames.contacts` for Windows —
// `Windows.ApplicationModel.Contacts.ContactStore` (WinRT). **Caveat**:
// yeh sirf woh contacts deta hai jo Windows "People" app / kisi
// connected account (Outlook, Google, waghera) se sync ho chuke hain —
// agar user ne kabhi koi account connect nahi kiya, list khaali aayegi.
// Yeh koi bug nahi hai, Windows ka apna contacts-store model hai.
class ContactsManager {
 public:
  static void Register(flutter::FlutterEngine* engine);
};

#endif  // DEVICE_AGENT_CONTACTS_MANAGER_H_
