//
//  NookIdentityPolyfill.js
//  Nook
//
//  Chrome Identity API polyfill for WKWebExtension support.
//  Injected into extension contexts to provide chrome.identity.launchWebAuthFlow().
//

(function() {
    'use strict';

    // Prevent double-injection
    if (window.__nookIdentityPolyfillInstalled) return;
    window.__nookIdentityPolyfillInstalled = true;

    // Pending requests storage
    var pendingRequests = {};

    // Generate a UUID v4
    function generateUUID() {
        if (typeof crypto !== 'undefined' && crypto.randomUUID) {
            return crypto.randomUUID();
        }
        // Fallback UUID generation
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
            var r = Math.random() * 16 | 0;
            var v = c === 'x' ? r : (r & 0x3 | 0x8);
            return v.toString(16);
        });
    }

    // Extract callback scheme from an OAuth URL
    function extractCallbackScheme(url) {
        try {
            var urlObj = new URL(url);
            var redirectUri = urlObj.searchParams.get('redirect_uri');
            if (redirectUri) {
                var redirectUrl = new URL(redirectUri);
                return redirectUrl.scheme;
            }
            // Check for custom scheme in the URL itself
            if (urlObj.protocol && urlObj.protocol !== 'https:' && urlObj.protocol !== 'http:') {
                return urlObj.protocol.replace(':', '');
            }
        } catch (e) {
            // Invalid URL, ignore
        }
        return null;
    }

    /**
     * Initiates an OAuth2 authentication flow.
     *
     * @param {Object} details - The authentication details
     * @param {string} details.url - The URL to open for authentication
     * @param {boolean} [details.interactive=true] - Whether to show UI
     * @param {Function} [callback] - Optional callback function
     * @returns {Promise<string>|undefined} - Promise resolving to the redirect URL (if no callback provided)
     */
    function launchWebAuthFlow(details, callback) {
        if (!details || typeof details !== 'object') {
            throw new Error('launchWebAuthFlow requires a details object');
        }

        if (!details.url) {
            throw new Error('launchWebAuthFlow requires a url in details');
        }

        var requestId = generateUUID();
        var interactive = details.interactive !== false;
        var callbackScheme = extractCallbackScheme(details.url);

        // Create the promise that will resolve when the flow completes
        var promise = new Promise(function(resolve, reject) {
            pendingRequests[requestId] = {
                resolve: resolve,
                reject: reject,
                callback: callback
            };

            // Post message to native handler
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.NookIdentity) {
                window.webkit.messageHandlers.NookIdentity.postMessage({
                    requestId: requestId,
                    url: details.url,
                    interactive: interactive,
                    prefersEphemeral: false,
                    callbackScheme: callbackScheme
                });
            } else {
                delete pendingRequests[requestId];
                var error = new Error('NookIdentity message handler not available');
                if (callback) {
                    callback(undefined);
                }
                reject(error);
            }
        });

        // If callback is provided, call it when promise resolves (Chrome-style)
        if (typeof callback === 'function') {
            promise.then(function(url) {
                callback(url);
            }).catch(function() {
                callback(undefined);
            });
            return undefined;
        }

        return promise;
    }

    /**
     * Generates a redirect URL for use in authentication flows.
     *
     * @param {string} [path] - Optional path to append
     * @returns {string} - The redirect URL
     */
    function getRedirectURL(path) {
        var baseUrl = 'https://nook-browser.app/oauth-callback';
        if (path) {
            // Ensure path starts with /
            var normalizedPath = path.startsWith('/') ? path : '/' + path;
            return baseUrl + normalizedPath;
        }
        return baseUrl;
    }

    /**
     * Callback function invoked by native code when identity flow completes.
     *
     * @param {Object} payload - The completion payload
     * @param {string} payload.requestId - The request ID
     * @param {string} payload.status - 'success', 'cancelled', or 'failure'
     * @param {string} [payload.url] - The final redirect URL (on success)
     * @param {string} [payload.code] - Error code (on failure)
     * @param {string} [payload.message] - Error message (on failure)
     */
    window.__nookCompleteIdentityFlow = function(payload) {
        if (!payload || typeof payload !== 'object') {
            console.error('[NookIdentity] Invalid payload received');
            return;
        }

        var requestId = payload.requestId;
        var request = pendingRequests[requestId];

        if (!request) {
            console.warn('[NookIdentity] No pending request found for ID:', requestId);
            return;
        }

        delete pendingRequests[requestId];

        var status = payload.status;

        if (status === 'success') {
            var url = payload.url;
            if (request.callback) {
                // Chrome-style: callback with URL, error in runtime.lastError
                request.resolve(url);
            } else {
                request.resolve(url);
            }
        } else if (status === 'cancelled') {
            // Set runtime.lastError for Chrome compatibility
            if (typeof chrome !== 'undefined') {
                chrome.runtime.lastError = {
                    message: payload.message || 'Authentication cancelled by user.',
                    code: payload.code || 'cancelled'
                };
            }
            if (request.callback) {
                request.resolve(undefined);
            } else {
                request.reject(new Error(payload.message || 'Authentication cancelled'));
            }
        } else {
            // Failure
            var errorMessage = payload.message || 'Authentication failed';
            if (typeof chrome !== 'undefined') {
                chrome.runtime.lastError = {
                    message: errorMessage,
                    code: payload.code || 'error'
                };
            }
            if (request.callback) {
                request.resolve(undefined);
            } else {
                request.reject(new Error(errorMessage));
            }
        }
    };

    // Build the identity API object
    var identityAPI = {
        launchWebAuthFlow: launchWebAuthFlow,
        getRedirectURL: getRedirectURL
    };

    // Install on chrome namespace
    if (typeof chrome === 'undefined') {
        window.chrome = {};
    }
    if (!chrome.identity) {
        chrome.identity = identityAPI;
    }

    // Install on browser namespace (Firefox-style)
    if (typeof browser === 'undefined') {
        window.browser = {};
    }
    if (!browser.identity) {
        browser.identity = identityAPI;
    }

    // Also expose on window for debugging
    window.__nookIdentity = identityAPI;

    console.log('[NookIdentity] Polyfill installed successfully');
})();
