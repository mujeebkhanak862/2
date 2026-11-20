// contacts_manager.h
#ifndef DEVICE_AGENT_CONTACTS_MANAGER_H_
#define DEVICE_AGENT_CONTACTS_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.contacts` for Linux —
// **Evolution Data Server (EDS)** ke through, jo GNOME/Evolution/
// Thunderbird ecosystem mein contacts ka standard backend hai.
// **Caveat**: yeh universal nahi hai — agar EDS install/running nahi hai
// (kuch minimal-DE ya server distros par nahi hota), `isAvailable()`
// false dega aur listContacts empty/error dega. Koi doosra
// distro-agnostic "system contacts" API Linux par exist nahi karta.
void contacts_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_CONTACTS_MANAGER_H_
