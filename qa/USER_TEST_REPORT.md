# "Ek user ki tarah" test — report

## Maine kya kiya
Asli Chromium browser (Playwright se) mein website (`web_dashboard/index.html`)
kholi aur ek insaan jaisa use kiya: galat password try kiya, login kiya, device
list dekhi, device chuna, Watch Live dabaya, screen par click/drag kiya (tap
aur swipe), Back button dabaya, text type kiya, clipboard bheja aur padha,
awaaz ON ki, "signal" meter dekha, Stop dabaya, offline device check kiya,
aur Logout kiya. Pura session recording ke console errors bhi check kiye.

**Backend (Dart server) is sandbox mein chal nahi sakta** (na Dart hai, na
internet). Isliye server ko ek chhoti si "fake" jagah se jawab dene ke liye
mock kiya — par **website ka asli code** (`index.html` mein jo bhi JavaScript
hai) hi chala, maine kuch bhi alag se nahi likha jo test ho raha hai.

## Natija
**38 mein se 38 cheezein pass huin** (`user_test.mjs` chalane se yeh dobara
dekha ja sakta hai). Ek screenshot bhi hai: `screenshot_live_view.png`.

## Is test ne 2 asli bugs pakde, dono fix ho gaye
1. **Swipe ka test pehle galat tha** mere chhote mock image ki wajah se (test
   ki apni galti thi, website ki nahi) — frame ko real phone jaisa size
   (270×600) diya to sahi pass hua: drag karne se `input.swipe` jata hai,
   sirf click se `input.tap`.
2. **Console-error check galti se wrong-password ke apne hi test step ke 401
   ko pakad raha tha** — browser khud failed network request ko ek "console
   error" ki tarah dikhata hai, ye crash nahi hai. Test ko theek kiya taaki
   sirf asli JavaScript errors pakde.

## Yeh test kya SAABIT karta hai
- Login/logout, device list render, Watch Live start/stop, tap-to-coordinate
  math (device ke real screen size 1080×2400 ke hisaab se sahi jagah par tap
  jaata hai), swipe, Back/Home/Recents keys, text typing, clipboard
  send/read, audio toggle, aur ping meter — sab asli browser mein, asli click
  se, bina kisi JS error ke chalte hain.
- Jo server se aana chahiye (`screen.watch_live` ka result, frames, audio
  chunks) agar bheja jaaye, to website use sahi dikhati/bajati/bhejti hai.

## Yeh test kya SAABIT NAHI karta (honest limits)
- **Asli Dart server** is tarah bilkul kaam karega, yeh is test se pata nahi
  chalta — maine jo responses "mock" kiye hain wahi maine khud `STAGE9_CHANGES.md`
  mein likhe protocol ke hisaab se banaye hain. Agar meri likhi hui Dart file
  mein koi bug hai (jo bina compile kiye ho sakta hai), yeh test use nahi
  pakdega.
- **Asli Android phone** audio/screen capture sahi dega ya nahi, Accessibility
  se tap sahi chalega ya nahi — iske liye real device chahiye.
- **Network ki asli speed/latency** (jo real deployment mein hogi) yahan
  nahi mapi gayi — "19 ms" wala ping sirf mock ka turant jawab tha.

## Kaise dobara chalayein
```
cd qa
node user_test.mjs
```
(Node aur Playwright chahiye — Playwright ka Chromium pehle se is machine
par install tha; aapke apne computer par `npx playwright install chromium`
chalana padega agar na ho.)
