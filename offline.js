// Install and offline pack UI (the "INSTALL & OFFLINE" card in the Control Center).
//
// - collectPackUrls(scope) is the ONLY place that decides which audio files belong to an offline pack. It walks
//   AUDIO_REGISTRY through the same helpers the unit cards use (resolveUnitAudio, getAbilitySources in app.js),
//   so the pack holds exactly the files a card can play. Nothing is built from folder names.
// - The service worker (sw.js) downloads into the `media` cache; this file only reads that cache and decides what
//   to add and remove. Unit audio paths carry a `?v=<hash>` stamp from generate-registry.ps1, so a file replaced
//   under the same name is a different URL: it is downloaded again and the old copy is removed as an orphan.
(() => {
    const MEDIA_CACHE = 'media';
    const SCOPE_STORAGE_KEY = 'offlinePackScope';
    const ALL_FACTIONS = ['terran', 'zerg', 'protoss'];

    let isBusy = false;
    let installPromptEvent = null;

    /* ======================================================================
       PACK CONTENT (pure, no browser storage involved)
       ====================================================================== */
    // Scope is plain data: { factions: [...], banks: ['sc1', 'sc2'], includeOst: false }.
    function collectPackUrls(scope) {
        const registry = window.AUDIO_REGISTRY;
        const urls = new Set();

        scope.factions.forEach(faction => {
            const factionUnits = registry.units[faction] || {};
            Object.keys(factionUnits).forEach(unitKey => {
                const config = registry.unitConfigs[faction][unitKey];
                const sc1Audio = getSwitchableSc1Audio(registry, faction, unitKey, config);
                // Same rule as the card: units without a switchable SC1 bank only ever play their base audio.
                const banks = sc1Audio ? scope.banks : ['sc2'];
                const abilities = [...Object.values(config.regular_abilities || {}), ...Object.values(config.additional_abilities || {})];

                banks.forEach(bank => {
                    const audio = resolveUnitAudio(factionUnits[unitKey], sc1Audio, bank);
                    abilities.forEach(ability => {
                        getAbilitySources(ability, bank).forEach(source => (audio[source] || []).forEach(url => urls.add(url)));
                    });
                });
            });

            if (scope.includeOst) {
                Object.values(registry.ost || {}).forEach(versionTracks => (versionTracks[faction] || []).forEach(url => urls.add(url)));
            }
        });
        return [...urls];
    }

    // Mirrors renderUnitCard: mode cards (e.g. Nova) have no SC1 switch, other units have one when an sc1/ bank exists.
    function getSwitchableSc1Audio(registry, faction, unitKey, config) {
        if (config.unit.mode_group) return null;
        const sc1Audio = registry.unitsSC1 && registry.unitsSC1[faction] && registry.unitsSC1[faction][unitKey];
        return sc1Audio && Object.keys(sc1Audio).length > 0 ? sc1Audio : null;
    }

    const toAbsoluteUrl = url => new URL(url, document.baseURI).href;

    /* ======================================================================
       CACHE ACCESS AND PACK OPERATIONS
       ====================================================================== */
    async function listCachedUrls() {
        if (!window.caches || !(await caches.has(MEDIA_CACHE))) return [];
        const cache = await caches.open(MEDIA_CACHE);
        return (await cache.keys()).map(request => request.url);
    }

    // Compares what the scope needs with what is stored.
    async function getPackDiff(scope) {
        const needed = new Set(collectPackUrls(scope).map(toAbsoluteUrl));
        const cached = new Set(await listCachedUrls());
        return {
            neededCount: needed.size,
            cachedCount: cached.size,
            missing: [...needed].filter(url => !cached.has(url)),
            orphans: [...cached].filter(url => !needed.has(url))
        };
    }

    // Downloading only needs the active worker, not a page it controls (a fresh install does not control the page
    // that registered it until the next load).
    async function getActiveWorker() {
        const registration = await navigator.serviceWorker.ready;
        return registration.active;
    }

    function downloadThroughWorker(worker, urls, onProgress) {
        return new Promise(resolve => {
            const onMessage = event => {
                const message = event.data || {};
                if (message.type === 'cache-progress') onProgress(message.done, message.total, message.failed);
                if (message.type === 'cache-done') {
                    navigator.serviceWorker.removeEventListener('message', onMessage);
                    resolve({ total: message.total, failed: message.failed });
                }
            };
            navigator.serviceWorker.addEventListener('message', onMessage);
            worker.postMessage({ type: 'cache-urls', urls });
        });
    }

    // Makes the media cache match the scope: removes orphans, downloads what is missing.
    async function prepare(scope, onProgress = () => {}) {
        const worker = await getActiveWorker();
        const diff = await getPackDiff(scope);

        if (diff.orphans.length > 0) {
            const cache = await caches.open(MEDIA_CACHE);
            await Promise.all(diff.orphans.map(url => cache.delete(url)));
        }
        let failed = 0;
        if (diff.missing.length > 0) {
            ({ failed } = await downloadThroughWorker(worker, diff.missing, onProgress));
        }
        // Asks the browser not to evict the offline data under storage pressure (ignored where unsupported).
        if (navigator.storage && navigator.storage.persist) navigator.storage.persist().catch(() => {});

        saveScope(scope);
        return { downloaded: diff.missing.length - failed, failed, removed: diff.orphans.length };
    }

    async function clearOfflineData() {
        if (window.caches) await caches.delete(MEDIA_CACHE);
        try { localStorage.removeItem(SCOPE_STORAGE_KEY); } catch (error) { /* storage unavailable */ }
    }

    /* ======================================================================
       SCOPE PERSISTENCE
       ====================================================================== */
    function loadSavedScope() {
        try {
            const stored = JSON.parse(localStorage.getItem(SCOPE_STORAGE_KEY));
            if (stored && Array.isArray(stored.factions)) {
                return {
                    factions: stored.factions.filter(faction => ALL_FACTIONS.includes(faction)),
                    banks: ['sc1', 'sc2'],
                    includeOst: !!stored.includeOst
                };
            }
        } catch (error) { /* no saved scope */ }
        return null;
    }

    function saveScope(scope) {
        try { localStorage.setItem(SCOPE_STORAGE_KEY, JSON.stringify(scope)); } catch (error) { /* storage unavailable */ }
    }

    /* ======================================================================
       UI
       ====================================================================== */
    function formatBytes(bytes) {
        return bytes >= 1024 * 1024 * 1024 ? `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB` : `${Math.round(bytes / 1024 / 1024)} MB`;
    }

    function initOfflineCard() {
        const ui = {
            installStatus: document.getElementById('install-status'),
            installButton: document.getElementById('btn-install-app'),
            iosHint: document.getElementById('install-ios-hint'),
            prepareButton: document.getElementById('btn-offline-prepare'),
            clearButton: document.getElementById('btn-offline-clear'),
            progress: document.getElementById('offline-progress'),
            progressBar: document.getElementById('offline-progress-bar'),
            status: document.getElementById('offline-status'),
            ost: document.getElementById('offline-ost'),
            factions: Object.fromEntries(ALL_FACTIONS.map(faction => [faction, document.getElementById(`offline-${faction}`)]))
        };
        if (!ui.prepareButton) return;

        const readScope = () => ({
            factions: ALL_FACTIONS.filter(faction => ui.factions[faction].checked),
            banks: ['sc1', 'sc2'],
            includeOst: ui.ost.checked
        });
        const applyScope = scope => {
            ALL_FACTIONS.forEach(faction => { ui.factions[faction].checked = scope.factions.includes(faction); });
            ui.ost.checked = scope.includeOst;
        };
        const setStatus = (text, tone = '') => {
            ui.status.textContent = text;
            ui.status.className = `offline-status${tone ? ` ${tone}` : ''}`;
        };
        const setProgress = fraction => {
            ui.progress.hidden = fraction === null;
            if (fraction === null) return;
            const percent = Math.round(fraction * 100);
            ui.progressBar.style.width = `${percent}%`;
            ui.progress.setAttribute('aria-valuenow', String(percent));
        };
        const setControlsDisabled = disabled => {
            ui.prepareButton.disabled = disabled;
            ui.clearButton.disabled = disabled;
            Object.values(ui.factions).forEach(input => { input.disabled = disabled; });
            ui.ost.disabled = disabled;
        };

        const isSupported = 'serviceWorker' in navigator && !!window.caches;
        const isWorkerEnabled = isSupported && window.swEnabled === true;

        /* ---- Offline sounds status ---- */
        const refreshStatus = async () => {
            if (!isSupported) {
                setControlsDisabled(true);
                setStatus('Offline mode is not available in this browser (it needs HTTPS).', 'is-warning');
                return;
            }
            if (!isWorkerEnabled) {
                setControlsDisabled(true);
                setStatus('Offline mode is switched off here (local development). Add ?sw=1 to the address to test it.', 'is-warning');
                return;
            }
            const scope = readScope();
            ui.prepareButton.disabled = isBusy || scope.factions.length === 0;
            const diff = await getPackDiff(scope);

            if (diff.cachedCount === 0) {
                ui.prepareButton.textContent = 'PREPARE OFFLINE';
                setStatus(scope.factions.length === 0
                    ? 'Select at least one faction to prepare offline sounds.'
                    : `Not downloaded yet: ${diff.neededCount} sounds for the selection.`);
            } else if (diff.missing.length === 0 && diff.orphans.length === 0) {
                ui.prepareButton.textContent = 'UPDATE OFFLINE DATA';
                const usage = navigator.storage && navigator.storage.estimate ? (await navigator.storage.estimate()).usage : 0;
                setStatus(`Ready for offline use: ${diff.neededCount} sounds${usage ? `, ${formatBytes(usage)} stored by this app` : ''}.`, 'is-ready');
            } else {
                ui.prepareButton.textContent = 'UPDATE OFFLINE DATA';
                setStatus(`Changes pending: ${diff.missing.length} to download, ${diff.orphans.length} to remove.`, 'is-warning');
            }
            ui.clearButton.disabled = isBusy || diff.cachedCount === 0;
        };

        const runPrepare = async ({ isSilent }) => {
            if (isBusy) return;
            isBusy = true;
            setControlsDisabled(true);
            setProgress(0);
            setStatus('Preparing offline sounds...');
            try {
                const result = await prepare(readScope(), (done, total) => {
                    setProgress(total ? done / total : 1);
                    setStatus(`Downloading ${done} / ${total}...`);
                });
                if (typeof showToast === 'function') {
                    showToast(result.failed > 0
                        ? `OFFLINE DATA INCOMPLETE: ${result.failed} SOUNDS FAILED`
                        : (isSilent ? 'OFFLINE SOUNDS UPDATED' : 'OFFLINE SOUNDS READY'));
                }
            } catch (error) {
                console.warn('Offline preparation failed:', error);
                if (typeof showToast === 'function') showToast('OFFLINE PREPARATION FAILED');
            } finally {
                isBusy = false;
                setProgress(null);
                setControlsDisabled(false);
                await refreshStatus();
            }
        };

        ui.prepareButton.addEventListener('click', () => runPrepare({ isSilent: false }));
        ui.clearButton.addEventListener('click', async () => {
            await clearOfflineData();
            if (typeof showToast === 'function') showToast('OFFLINE DATA REMOVED');
            await refreshStatus();
        });
        [...Object.values(ui.factions), ui.ost].forEach(input => input.addEventListener('change', refreshStatus));

        const savedScope = loadSavedScope();
        if (savedScope) applyScope(savedScope);
        refreshStatus().then(async () => {
            // A pack the user prepared earlier is kept current: after a release only new or changed files are fetched.
            if (!savedScope || !isWorkerEnabled || !navigator.onLine || !navigator.serviceWorker.controller) return;
            const diff = await getPackDiff(savedScope);
            if (diff.missing.length > 0 || diff.orphans.length > 0) runPrepare({ isSilent: true });
        });

        /* ---- Install ---- */
        const isStandalone = () => window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
        const isIos = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

        const renderInstall = () => {
            ui.installButton.hidden = true;
            ui.iosHint.hidden = true;
            if (isStandalone()) {
                ui.installStatus.textContent = 'Installed: running as an app.';
                ui.installStatus.className = 'offline-status is-ready';
                return;
            }
            ui.installStatus.className = 'offline-status';
            if (installPromptEvent) {
                ui.installStatus.textContent = 'This app can be installed on this device.';
                ui.installButton.hidden = false;
            } else if (isIos) {
                ui.installStatus.textContent = 'Install it from the browser share menu.';
                ui.iosHint.hidden = false;
            } else {
                ui.installStatus.textContent = 'Install it from the browser menu (Install app or Add to Home Screen) when the browser offers it.';
            }
        };

        window.addEventListener('beforeinstallprompt', event => {
            event.preventDefault();
            installPromptEvent = event;
            renderInstall();
        });
        window.addEventListener('appinstalled', () => {
            installPromptEvent = null;
            renderInstall();
        });
        ui.installButton.addEventListener('click', async () => {
            if (!installPromptEvent) return;
            installPromptEvent.prompt();
            await installPromptEvent.userChoice;
            installPromptEvent = null;
            renderInstall();
        });
        renderInstall();
    }

    window.OfflinePack = { collectPackUrls, getPackDiff, prepare, clearOfflineData };
    initOfflineCard();
})();
