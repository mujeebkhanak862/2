// contacts_manager.cc
#include "contacts_manager.h"

#include <libebook/libebook.h>
#include <libedataserver/libedataserver.h>

#include <string>
#include <vector>

namespace {
constexpr char kChannel[] = "device_agent/contacts";

// Registry mein saare "address book" type sources dhoondhta hai
// (Evolution/Thunderbird/Google-synced address books, jo bhi user ne
// configure kiya ho).
GList* ListAddressBookSources(ESourceRegistry* registry) {
  return e_source_registry_list_sources(registry, E_SOURCE_EXTENSION_ADDRESS_BOOK);
}

bool ConnectFirstAvailableBook(ESourceRegistry* registry, EBookClient** out_client) {
  GList* sources = ListAddressBookSources(registry);
  bool connected = false;
  for (GList* l = sources; l != nullptr && !connected; l = l->next) {
    ESource* source = E_SOURCE(l->data);
    GError* error = nullptr;
    EClient* client = e_book_client_connect_sync(source, 10, nullptr, &error);
    if (client != nullptr) {
      *out_client = E_BOOK_CLIENT(client);
      connected = true;
    } else if (error != nullptr) {
      g_error_free(error);
    }
  }
  g_list_free_full(sources, g_object_unref);
  return connected;
}

std::vector<std::string> GetAttributeValues(EContact* contact, EContactField field) {
  std::vector<std::string> values;
  GList* attrs = static_cast<GList*>(e_contact_get(contact, field));
  for (GList* l = attrs; l != nullptr; l = l->next) {
    // TEL/EMAIL fields plain strings ke tor par aate hain e_contact_get
    // se (attribute objects nahi) — is API surface mein.
    const char* value = static_cast<const char*>(l->data);
    if (value != nullptr) values.emplace_back(value);
  }
  g_list_free_full(attrs, g_free);
  return values;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  GError* error = nullptr;
  ESourceRegistry* registry = e_source_registry_new_sync(nullptr, &error);
  if (registry == nullptr) {
    if (error) g_error_free(error);
    if (g_strcmp0(method, "isAvailable") == 0) {
      g_autoptr(FlValue) result = fl_value_new_bool(false);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "EDS_UNAVAILABLE",
          "Evolution Data Server tak connect nahi ho saka — install/running "
          "nahi hai",
          nullptr));
    }
    goto respond;
  }

  if (g_strcmp0(method, "isAvailable") == 0) {
    GList* sources = ListAddressBookSources(registry);
    bool available = sources != nullptr;
    g_list_free_full(sources, g_object_unref);
    g_autoptr(FlValue) result = fl_value_new_bool(available);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else if (g_strcmp0(method, "requestPermission") == 0) {
    EBookClient* client = nullptr;
    bool ok = ConnectFirstAvailableBook(registry, &client);
    if (client) g_object_unref(client);
    g_autoptr(FlValue) result = fl_value_new_bool(ok);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else if (g_strcmp0(method, "listContacts") == 0) {
    EBookClient* client = nullptr;
    if (!ConnectFirstAvailableBook(registry, &client)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "PERMISSION_DENIED",
          "Koi address book source connect nahi ho saki", nullptr));
    } else {
      EBookQuery* query = e_book_query_any_field_contains("");
      gchar* query_str = e_book_query_to_string(query);
      e_book_query_unref(query);

      GSList* contacts = nullptr;
      GError* query_error = nullptr;
      e_book_client_get_contacts_sync(client, query_str, &contacts, nullptr,
                                       &query_error);
      g_free(query_str);

      g_autoptr(FlValue) list = fl_value_new_list();
      for (GSList* l = contacts; l != nullptr; l = l->next) {
        EContact* contact = E_CONTACT(l->data);
        g_autoptr(FlValue) m = fl_value_new_map();

        const char* uid = static_cast<const char*>(
            e_contact_get_const(contact, E_CONTACT_UID));
        const char* name = static_cast<const char*>(
            e_contact_get_const(contact, E_CONTACT_FULL_NAME));

        fl_value_set_string_take(m, "id",
                                  fl_value_new_string(uid ? uid : ""));
        fl_value_set_string_take(m, "name",
                                  fl_value_new_string(name ? name : ""));

        g_autoptr(FlValue) phones = fl_value_new_list();
        for (auto& p : GetAttributeValues(contact, E_CONTACT_TEL)) {
          fl_value_append_take(phones, fl_value_new_string(p.c_str()));
        }
        fl_value_set_string_take(m, "phoneNumbers", fl_value_ref(phones));

        g_autoptr(FlValue) emails = fl_value_new_list();
        for (auto& e : GetAttributeValues(contact, E_CONTACT_EMAIL)) {
          fl_value_append_take(emails, fl_value_new_string(e.c_str()));
        }
        fl_value_set_string_take(m, "emails", fl_value_ref(emails));

        fl_value_append(list, m);
      }
      g_slist_free_full(contacts, g_object_unref);
      if (query_error) g_error_free(query_error);
      g_object_unref(client);

      response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }

  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

respond:
  g_object_unref(registry);
  g_autoptr(GError) respond_error = nullptr;
  if (!fl_method_call_respond(method_call, response, &respond_error)) {
    g_warning("Contacts channel response failed: %s", respond_error->message);
  }
}
}  // namespace

void contacts_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
