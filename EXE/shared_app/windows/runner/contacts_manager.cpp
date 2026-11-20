// contacts_manager.cpp
#include "contacts_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.ApplicationModel.Contacts.h>
#include <winrt/Windows.Foundation.Collections.h>

#include <memory>
#include <string>

using namespace winrt::Windows::ApplicationModel::Contacts;

namespace {
constexpr char kChannel[] = "device_agent/contacts";

std::string WideToUtf8(winrt::hstring const& wide) {
  if (wide.empty()) return "";
  std::wstring w(wide);
  int size = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                                  nullptr, 0, nullptr, nullptr);
  std::string utf8(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                       utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// `AllContactsReadOnly` — poore system contacts store tak read access
// maangta hai (consent prompt Windows khud dikhata hai). Non-MSIX-
// packaged Win32 apps ke liye yeh access **partially/unreliably** kaam
// karta hai — Microsoft docs ke mutabiq poori Contacts API surface
// officially packaged (MSIX) apps ke liye design hui hai. Yeh maine
// pehle bhi bataya tha Location ke context mein — yahan bhi wahi caveat
// lagta hai.
bool TryOpenContactStore(ContactStore* out) {
  try {
    *out = ContactManager::RequestStoreAsync(
                ContactStoreAccessType::AllContactsReadOnly)
               .get();
    return *out != nullptr;
  } catch (...) {
    return false;
  }
}
}  // namespace

void ContactsManager::Register(flutter::FlutterEngine* engine) {
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "isAvailable") {
          // Contacts API Windows 10+ par present hoti hai — asal
          // availability (koi account connected hai ya nahi) sirf
          // requestPermission/listContacts try karne par pata chalti hai.
          result->Success(flutter::EncodableValue(true));

        } else if (call.method_name() == "requestPermission") {
          ContactStore store{nullptr};
          bool ok = TryOpenContactStore(&store);
          result->Success(flutter::EncodableValue(ok));

        } else if (call.method_name() == "listContacts") {
          ContactStore store{nullptr};
          if (!TryOpenContactStore(&store)) {
            result->Error("PERMISSION_DENIED",
                           "Contacts store access nahi mila");
            return;
          }

          try {
            auto contacts = store.FindContactsAsync().get();
            flutter::EncodableList list;
            for (auto contact : contacts) {
              flutter::EncodableMap m;
              m[flutter::EncodableValue("id")] =
                  flutter::EncodableValue(WideToUtf8(contact.Id()));
              m[flutter::EncodableValue("name")] =
                  flutter::EncodableValue(WideToUtf8(contact.FullName()));

              flutter::EncodableList phones;
              for (auto phone : contact.Phones()) {
                phones.push_back(
                    flutter::EncodableValue(WideToUtf8(phone.Number())));
              }
              m[flutter::EncodableValue("phoneNumbers")] =
                  flutter::EncodableValue(phones);

              flutter::EncodableList emails;
              for (auto email : contact.Emails()) {
                emails.push_back(
                    flutter::EncodableValue(WideToUtf8(email.Address())));
              }
              m[flutter::EncodableValue("emails")] =
                  flutter::EncodableValue(emails);

              list.push_back(flutter::EncodableValue(m));
            }
            result->Success(flutter::EncodableValue(list));
          } catch (...) {
            result->Error("READ_FAILED", "Contacts read karte waqt error aayi");
          }

        } else {
          result->NotImplemented();
        }
      });
}
