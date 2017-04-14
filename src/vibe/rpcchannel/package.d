/**
 * Provides access to the vibe.rpcchannel modules.
 *
 * This excludes vibe.rpcchannel.noise which is in a extra dub package and
 * needs to be imported explicitly.
 * Start reading the documentation by looking at the vibe.rpcchannel.tcp
 * and vibe.rpcchannel.noise modules.
 */
module vibe.rpcchannel;

public import vibe.rpcchannel.base, vibe.rpcchannel.server,
    vibe.rpcchannel.client, vibe.rpcchannel.tcp;
