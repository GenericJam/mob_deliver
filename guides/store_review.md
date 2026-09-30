# Store review

mob_deliver downloads BEAM bytecode at runtime. Both stores have rules about
code an app didn't ship with, so every submission of a mob_deliver app should
be prepared for the question. This page quotes the rules (retrieved
2026-09-30 — re-check before relying on them), explains where mob_deliver
sits, and gives reviewer-note text. It is not legal advice.

## Apple

**Apple Developer Program License Agreement, §3.3.1(B) "Executable Code"**
([source](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)):

> Except as set forth in the next paragraph, an Application may not download
> or install executable code. Interpreted code may be downloaded to an
> Application but only so long as such code: (a) does not change the primary
> purpose of the Application by providing features or functionality that are
> inconsistent with the intended and advertised purpose of the Application
> (b) does not bypass signing, sandbox, or other security features of the OS;
> and (c) for Applications distributed on the App Store, does not create a
> store or storefront for other Applications.

**App Review Guideline 2.5.2**
([source](https://developer.apple.com/app-store/review/guidelines/)):

> Apps should be self-contained in their bundles, and may not read or write
> data outside the designated container area, nor may they download, install,
> or execute code which introduces or changes features or functionality of
> the app, including other apps. […]

The two pull in different directions: the license agreement permits
downloaded interpreted code within limits; the guideline reviewers cite
forbids code that "introduces or changes features". Over-the-air JavaScript
updates (React Native CodePush, Expo Updates) have shipped for years under
the §3.3.1(B) allowance, typically for fixes and content rather than new
product surface. mob_deliver makes the same claim for BEAM bytecode and should
be used the same way.

Where mob_deliver sits:

* **Interpreted code.** Delivered `.beam` files run on the BEAM VM that ships
  inside the reviewed binary. On iOS the BEAM runs as an interpreter — iOS
  forbids JIT — so nothing is compiled to native code at runtime, and no
  native code (NIFs, frameworks) is ever downloaded.
* **(b) Signing and sandbox.** Every manifest is Ed25519-signed with a key
  baked into the reviewed binary, every `.beam` is SHA-256-checked against
  it, and it all lives in the app's own container. Nothing bypasses iOS code
  signing: the VM executing the bytecode is the signed binary.
* **(a) Primary purpose** and **(c) no storefront** are how you use it, not
  something the library enforces. Ship fixes and screens that belong to the
  app you submitted; don't use expansion screens to deliver a different app
  or a catalogue of apps.
* **Guideline 2.5.2 risk.** A reviewer can still read a delivered feature as
  "changes features or functionality". Keep the reviewed build complete
  (the store build should work without any delivered code), and prefer
  delivering fixes and content over new capabilities.

## Google Play

**Device and Network Abuse policy**
([source](https://support.google.com/googleplay/android-developer/answer/16559646)):

> An app distributed via Google Play may not modify, replace, or update itself
> using any method other than Google Play's update mechanism. Likewise, an app
> may not download executable code (such as dex, JAR, .so files) from a source
> other than Google Play. This restriction does not apply to code that runs in
> a virtual machine or an interpreter where either provides indirect access to
> Android APIs (such as JavaScript in a webview or browser).
>
> Apps or third-party code, like SDKs, with interpreted languages (JavaScript,
> Python, Lua, etc.) loaded at run time (for example, not packaged with the
> app) must not allow potential violations of Google Play policies.

BEAM bytecode runs in a virtual machine and reaches Android APIs only
indirectly, through the NIFs and plugins compiled into the Play-distributed
binary — the exception the policy describes. Delivered code is still subject
to every other Play policy.

## Reviewer note

Paste into App Store Connect's "Notes" (and the Play Console equivalent) with
every submission of an app that activates mob_deliver:

> This app is written in Elixir and runs on the Erlang BEAM virtual machine,
> which is compiled into the app binary. The app can download signed BEAM
> bytecode that runs inside that virtual machine as interpreted code (Apple
> Developer Program License Agreement §3.3.1(B)); no native code is ever
> downloaded or executed. Downloaded code is limited to fixes and screens
> belonging to this app's reviewed purpose, is served from our own HTTPS
> servers, and is verified before use against an Ed25519 signature key that
> is embedded in this reviewed build. The reviewed build is fully functional
> without any downloaded code.

Adjust the last sentences to what your app actually does — if you use
expansion screens, say what they contain.
