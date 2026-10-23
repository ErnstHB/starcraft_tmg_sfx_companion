// Registers the service worker (see sw.js).
//
// - Not registered on localhost, so the no-store dev server stays a clean edit loop. Add ?sw=1 to test it locally.
// - ?nosw=1 is an escape hatch everywhere: it removes the service worker and the shell caches.
// - window.swEnabled tells the rest of the app (offline.js) whether the worker is active on this page.
(() => {
    window.swEnabled = false;
    if (!('serviceWorker' in navigator)) return;

    const params = new URLSearchParams(window.location.search);
    const isLocalhost = ['localhost', '127.0.0.1', '[::1]'].includes(window.location.hostname);
    const isEnabled = !params.has('nosw') && (!isLocalhost || params.has('sw'));
    window.swEnabled = isEnabled;

    if (isEnabled) {
        window.addEventListener('load', () => {
            navigator.serviceWorker.register('sw.js').catch(error => console.warn('Service worker registration failed:', error));
        });

        // A new release installs in the background and takes over; the open page keeps running the old files until reloaded.
        // The first takeover (no controller yet) is just the initial install and needs no notice.
        const hadController = !!navigator.serviceWorker.controller;
        navigator.serviceWorker.addEventListener('controllerchange', () => {
            if (hadController && typeof showToast === 'function') showToast('NEW VERSION INSTALLED. RELOAD TO UPDATE');
        });
        return;
    }

    // Disabled: drop any worker and shell caches from earlier visits (the media cache is the user's offline data and stays).
    navigator.serviceWorker.getRegistrations()
        .then(registrations => Promise.all(registrations.map(registration => registration.unregister())))
        .then(() => caches.keys())
        .then(names => Promise.all(names.filter(name => name.startsWith('shell-')).map(name => caches.delete(name))))
        .catch(error => console.warn('Service worker cleanup failed:', error));
})();
