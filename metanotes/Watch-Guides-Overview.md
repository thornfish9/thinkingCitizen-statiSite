# Watch-Guides.ps1 — Overview, How It Works, Debugging, and Enhancements

## Purpose

This script watches a folder of Word documents and converts them to Hugo-ready Markdown using Pandoc.

* **Watches:** `site\writing\guides\*.docx`
* **Writes:**  `site\content\guides\<slug>.md`
* **Adds:** Hugo front matter (`title`, `date`, `draft`) based on the source file
* **Logs:** console output for major events and conversion results

It is designed as **infrastructure-style tooling**: long-running, event-driven, safe to restart, and structured as reusable functions.

---

## High-level architecture

The key design is a **two-stage pipeline**:

1. **Event ingestion (FileSystemWatcher event handlers)**

   * Runs in an **event action runspace** (PowerShell event subsystem)
   * Does the absolute minimum: **enqueue changed file paths**

2. **Processing loop (main runspace)**

   * Runs deterministically in the script’s main thread
   * Dequeues paths, debounces, waits for file readiness, runs Pandoc, writes Markdown

This avoids PowerShell’s runspace pitfalls while preserving a function-based architecture.

---

## Why the two-stage design matters (runspace / hook pitfalls)

### The problem

In PowerShell, `Register-ObjectEvent -Action { ... }` handlers often run in a **different runspace** than your main script.

Symptoms when you try to call your script functions from inside `-Action`:

* Event fires, but handler appears to do nothing
* No console output from the handler
* Calls to helper functions may fail because those functions are not visible in that runspace
* Failures may be silent or hard to observe

This is a classic trap when refactoring a “working” inline script into functions.

### How we avoided it

We deliberately kept event handler code **self-contained and minimal**:

* The event handler **does not call your functions**.
* The event handler simply appends the changed file path to a **pending queue file** (e.g. `_pending-paths.txt`).

Then the main runspace loop reads that pending file and performs all real work by calling functions normally.

This is the stable pattern:

* **Hooks only enqueue**
* **Main loop does work**

It also maps directly to how you’d structure this in C# later.

---

## Core components and responsibilities

### 1) Path resolution

`Get-TCGuidePaths`

* Derives `SiteRoot`, `WritingDir`, `OutDir` from `$PSScriptRoot`
* Keeps the script relocatable within the repo structure

### 2) Logging

`Write-TCLog`

* Writes to console
* Can be extended to write to files (recommended)

### 3) Watcher lifecycle

* `New-TCGuideWatcher`: constructs a `System.IO.FileSystemWatcher`
* `Start-TCGuideWatcher`: sets up the watcher, registers event handlers, enables raising events
* `Stop-TCGuideWatcher`: unregisters handlers, disposes watcher, sets stop flag

### 4) Event ingestion (queue)

The event action:

* Appends changed file paths to `_pending-paths.txt`
* Must be extremely small and resilient

### 5) Processing loop

`Run-TCGuideProcessorLoop`

* Polls for pending paths
* Deduplicates and debounces
* Invokes conversion logic in a reliable context

### 6) Conversion logic

`Convert-GuideDocxToMarkdown`

* Validates path and extension
* Waits for file readiness (`Wait-TCFileReady`) to avoid Word-save locks
* Computes slug (`ConvertTo-TCSlug`)
* Runs Pandoc to a temp file
* Builds front matter (`New-TCFrontMatter`) from real title/date
* Prepends front matter and writes final `.md`

### 7) Front matter

`New-TCFrontMatter`

* Produces Hugo YAML front matter
* Title from base filename
* Date from file last write time
* Draft default `true`

---

## How the script runs (basic flow)

1. Script starts
2. `Start-TCGuideWatcher`:

   * Resolves directories
   * Ensures folders exist
   * Creates watcher
   * Registers events (Changed/Created/Renamed)
   * Enables raising events
   * Initializes queue file path
3. `Run-TCGuideProcessorLoop`:

   * Loops until stop requested
   * Reads and clears `_pending-paths.txt`
   * Debounces rapid duplicates
   * Calls `Convert-GuideDocxToMarkdown`
4. Output `.md` appears in `site\content\guides`

---

## Debugging and observability

### The three-layer diagnostic model

When “nothing happens,” diagnose in this order:

#### Layer 1: Is the watcher firing?

**Check queue file activity:**

* Does `site\content\guides\_pending-paths.txt` exist and grow when you save a `.docx`?

If **NO**:

* Watcher registration or path mismatch problem
* Verify `WritingDir` in startup logs
* Confirm you are saving into the exact folder the script prints

If **YES**:

* Watcher is fine; problem is downstream

#### Layer 2: Is the processor loop running?

Symptoms of processor not running:

* `_pending-paths.txt` keeps growing
* No `DETECTED:` lines
* No conversions happen

Actions:

* Confirm entry point calls `Run-TCGuideProcessorLoop`
* Add a periodic “heartbeat” log inside the loop (optional)

#### Layer 3: Is conversion failing?

Symptoms:

* You see `DETECTED:` lines
* Pandoc errors or output issues

Actions:

* Capture Pandoc stderr and exit code
* Verify Pandoc is on PATH
* Verify the `.docx` is a real Word doc (not `copy con` fake)

### Recommended observability additions (small)

* Write to `OutDir\_watch.log` and `OutDir\_errors.log` in addition to console
* Record:

  * detected path
  * debounce decision
  * wait-for-ready outcome
  * pandoc command line and exit code

### Quick “proof” technique

If you ever need to prove hooks are firing:

* Temporarily change the event action to append to a dedicated `_baked-event-trace.log`
* This isolates hook behavior from the rest of the system

---

## Notes about file events and Word

* Word saves can trigger multiple events rapidly
* During save, the file can be temporarily locked
* The script uses:

  * **debounce** to prevent redundant conversions
  * **Wait-TCFileReady** to reduce lock-related failures

---

## Recommended enhancements (in priority order)

### 1) Atomic queue file handling (prevents edge-case event loss)

Current approach is “read then clear,” which can lose paths if an event appends mid-read.

Better approach:

* Rename `_pending-paths.txt` to `_pending-processing.txt` atomically
* Process the renamed file
* Delete it when done

This is a small change with a correctness payoff.

### 2) Retry strategy for locked / partially-written files

Even with `Wait-TCFileReady`, you can see intermittent failures.

Enhancement:

* If conversion is skipped due to lock, re-enqueue the path once (or N times with backoff)

### 3) Better Pandoc error capture

Today: checks `$LASTEXITCODE`.

Enhancement:

* Capture stderr to a log file
* Log the exact Pandoc invocation

### 4) Slug stability / rename behavior

Today slug is derived from filename.

Possible enhancements:

* If a file is renamed, decide whether to:

  * regenerate new slug and leave old md (current behavior), or
  * delete/redirect old md, or
  * track mapping in a small index file

### 5) Hugo front matter policy

Possible enhancements:

* Allow draft toggle based on naming convention or a settings file
* Support additional Hugo fields (`lastmod`, `slug`, `summary`, `tags`)

### 6) Exclusions and partial conversions

* Ignore temp Word files (e.g., `~$*.docx`)
* Ignore non-real `.docx` test files

### 7) Graceful shutdown

* Trap Ctrl+C / PowerShell exiting
* Call `Stop-TCGuideWatcher` cleanly
* Flush queue processing before exit

---

## When to switch to C# (short leash criteria)

PowerShell is fine for a dev-time tool, but switch to C# if you want:

* Background service / auto-start
* High-volume event bursts and guaranteed no loss
* More robust concurrency and backpressure
* Structured logging, metrics, and tests
* Single deployable executable

The current two-stage design (enqueue → process) ports directly to C#.

---

## Operational tips

* Run from PowerShell 7.x
* Start with no config inputs; keep it simple
* Use real `.docx` documents for testing (Word save), not fake “.docx extension” text files
* If behavior changes unexpectedly, use the three-layer diagnostic model above

---

## Summary

This script is intentionally structured as a robust tool:

* Watcher hooks are minimal and safe
* Main runspace loop does all real work
* Functions remain clean, testable units
* Observability strategy makes failures diagnosable

This is a stable foundation for adding features without regressing into fragile monoliths.
