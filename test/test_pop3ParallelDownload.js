/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/**
 * Tests the per-destination POP3 download lock (bug 1943854).
 *
 * - Two accounts that download into *different* inboxes must run
 *   concurrently.
 * - Two accounts deferred to the same inbox (global inbox) must stay strictly
 *   serialized.
 *
 * The fake server handlers are synchronous, so a session is held open by
 * spinning the event loop inside the STAT handler. While the "slow" account is
 * parked there, the "fast" account either gets to run (distinct destination) or
 * cannot even open its socket (shared destination). That makes the assertion
 * about the lock deterministic instead of timing based.
 */

var { PromiseTestUtils } = ChromeUtils.importESModule(
  "resource://testing-common/mailnews/PromiseTestUtils.sys.mjs"
);

// How long the "slow" account parks in STAT while waiting for its peer.
const kBarrierMs = 2000;

// Ordered log of POP3 commands, tagged with the account they belong to.
var gLog = [];

/**
 * Spin the event loop until `predicate` is true or `timeoutMs` elapses.
 * A repeating timer guarantees the blocking processNextEvent() always wakes up
 * so the deadline is honoured even when nothing else is queued.
 *
 * @param {Function} predicate - Called on every turn of the event loop.
 * @param {integer} timeoutMs - Give up after this many milliseconds.
 * @returns {boolean} The final value of the predicate.
 */
function spinUntil(predicate, timeoutMs) {
  const thread = Services.tm.currentThread;
  const deadline = Date.now() + timeoutMs;
  const timer = Cc["@mozilla.org/timer;1"].createInstance(Ci.nsITimer);
  timer.initWithCallback({ notify() {} }, 50, Ci.nsITimer.TYPE_REPEATING_SLACK);
  try {
    while (!predicate() && Date.now() < deadline) {
      thread.processNextEvent(true);
    }
  } finally {
    timer.cancel();
  }
  return predicate();
}

/**
 * Create a fake POP3 daemon/server pair whose handler appends every
 * interesting command to gLog as `${tag}:${command}`.
 *
 * @param {string} tag - Short name of the account, e.g. "A".
 * @param {?Function} barrier - If given, STAT spins the event loop until this
 *   returns true (or kBarrierMs elapses) before answering. Its return value is
 *   recorded in gLog as `${tag}:SAW_PEER` / `${tag}:NO_PEER`.
 * @returns {[Pop3Daemon, nsMailServer]}
 */
function setupTaggedServer(tag, barrier) {
  const daemon = new Pop3Daemon();
  const server = new nsMailServer(d => {
    const handler = new POP3_RFC5034_handler(d);
    for (const command of ["CAPA", "STAT", "QUIT"]) {
      const original = handler[command].bind(handler);
      handler[command] = args => {
        gLog.push(`${tag}:${command}`);
        if (command == "STAT" && barrier) {
          gLog.push(barrier() ? `${tag}:SAW_PEER` : `${tag}:NO_PEER`);
        }
        return original(args);
      };
    }
    return handler;
  }, daemon);
  server.start();
  daemon.setMessages(["message1.eml"]);
  return [daemon, server];
}

/**
 * Stop deferring `incomingServer` so it downloads into its own inbox, and
 * return that inbox.
 *
 * @param {nsIPop3IncomingServer} incomingServer
 * @returns {nsIMsgFolder}
 */
function undefer(incomingServer) {
  incomingServer.deferredToAccount = "";
  const localServer = incomingServer.QueryInterface(
    Ci.nsILocalMailIncomingServer
  );
  localServer.createDefaultMailboxes();
  localServer.setFlagsOnDefaultMailboxes();
  const inbox = incomingServer.rootMsgFolder.getFolderWithFlags(
    Ci.nsMsgFolderFlags.Inbox
  );
  Assert.ok(inbox, "the un-deferred account should have its own inbox");
  return inbox;
}

/**
 * Index of the first entry in gLog belonging to `tag`.
 *
 * @param {string} tag
 * @returns {integer} -1 when the account never talked to its server.
 */
function firstEntry(tag) {
  return gLog.findIndex(entry => entry.startsWith(`${tag}:`));
}

/**
 * Index of the last entry in gLog belonging to `tag`.
 *
 * @param {string} tag
 * @returns {integer}
 */
function lastEntry(tag) {
  return gLog.findLastIndex(entry => entry.startsWith(`${tag}:`));
}

function cleanUpServers(servers, incomingServers) {
  for (const incomingServer of incomingServers) {
    incomingServer.closeCachedConnections();
    MailServices.accounts.removeIncomingServer(incomingServer, false);
  }
  for (const server of servers) {
    server.stop();
  }
  const thread = Services.tm.currentThread;
  while (thread.hasPendingEvents()) {
    thread.processNextEvent(true);
  }
}

/**
 * Two accounts with distinct download destinations must overlap: while account
 * A is parked in STAT, account B must be able to run its whole session.
 */
add_task(async function testDistinctDestinationsRunConcurrently() {
  gLog = [];
  const [, serverA] = setupTaggedServer("A", () =>
    spinUntil(() => gLog.includes("B:QUIT"), kBarrierMs)
  );
  const [, serverB] = setupTaggedServer("B");

  // Distinct hostnames are required: MsgIncomingServer.serverURI is
  // `mailbox://<user>@<hostname>`, so two accounts with the same user@host
  // share one root folder (and would therefore share one lock key).
  const incomingA = createPop3ServerAndLocalFolders(serverA.port, "127.0.0.1");
  const incomingB = createPop3ServerAndLocalFolders(serverB.port, "localhost");
  const inboxA = undefer(incomingA);
  const inboxB = undefer(incomingB);
  Assert.notEqual(
    inboxA.URI,
    inboxB.URI,
    "the two accounts must download into different folders"
  );

  const listenerA = new PromiseTestUtils.PromiseUrlListener();
  const listenerB = new PromiseTestUtils.PromiseUrlListener();
  // Note: do not use server.performTest() here, it only tracks one fake
  // server and would block the other one from being serviced.
  MailServices.pop3.GetNewMail(null, listenerA, inboxA, incomingA);
  MailServices.pop3.GetNewMail(null, listenerB, inboxB, incomingB);
  await Promise.all([listenerA.promise, listenerB.promise]);

  Assert.ok(
    gLog.includes("A:SAW_PEER"),
    `account B should have completed while A was still connected, log: ${gLog}`
  );
  Assert.equal(inboxA.getTotalMessages(false), 1, "A downloaded its message");
  Assert.equal(inboxB.getTotalMessages(false), 1, "B downloaded its message");

  cleanUpServers([serverA, serverB], [incomingA, incomingB]);
});

/**
 * Two accounts deferred to the same (global) inbox must be serialized: while
 * account A is parked in STAT, account B must not connect at all.
 */
add_task(async function testSharedDestinationIsSerialized() {
  gLog = [];
  const [, serverA] = setupTaggedServer("A", () =>
    spinUntil(() => gLog.includes("B:CAPA"), kBarrierMs)
  );
  const [, serverB] = setupTaggedServer("B");

  // createPop3ServerAndLocalFolders() defers to the Local Folders account, so
  // both accounts share localAccountUtils.inboxFolder as their destination.
  const incomingA = createPop3ServerAndLocalFolders(serverA.port, "127.0.0.1");
  const incomingB = createPop3ServerAndLocalFolders(serverB.port, "localhost");
  Assert.equal(
    incomingA.rootMsgFolder.URI,
    incomingB.rootMsgFolder.URI,
    "both accounts must download into the same destination"
  );

  const inbox = localAccountUtils.inboxFolder;
  const before = inbox.getTotalMessages(false);

  const listenerA = new PromiseTestUtils.PromiseUrlListener();
  const listenerB = new PromiseTestUtils.PromiseUrlListener();
  MailServices.pop3.GetNewMail(null, listenerA, inbox, incomingA);
  MailServices.pop3.GetNewMail(null, listenerB, inbox, incomingB);
  await Promise.all([listenerA.promise, listenerB.promise]);

  Assert.ok(
    gLog.includes("A:NO_PEER"),
    `account B must not connect while A holds the lock, log: ${gLog}`
  );
  Assert.less(
    lastEntry("A"),
    firstEntry("B"),
    `the two sessions must not interleave, log: ${gLog}`
  );
  Assert.equal(
    inbox.getTotalMessages(false) - before,
    2,
    "both messages land in the shared inbox"
  );

  cleanUpServers([serverA, serverB], [incomingA, incomingB]);
});
