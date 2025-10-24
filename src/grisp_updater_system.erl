-module(grisp_updater_system).

%--- Includes ------------------------------------------------------------------

-include("grisp_updater.hrl").


%--- Types ---------------------------------------------------------------------

-type system_id() :: non_neg_integer().

-export_type([system_id/0]).


%--- Behaviour Definition ------------------------------------------------------

-doc """
Initialize the platform-specific HAL and return an opaque State. This
State is passed to all subsequent callbacks. Keep probing lightweight
(e.g., read environment, detect active slot), avoid writes here.
""".
-callback system_init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.
-doc """
Return the global #target{} representing the whole updatable medium
(e.g., disk/flash device and its base offset).

Optional: implement when your manifests use raw targets with
context=global or when the manager must derive absolute addresses from
structure. If not implemented and required, the manager fails with a
clear error (missing_global_target).
""".
-callback system_get_global_target(State :: term()) ->
    GlobalTarget :: target().
-doc """
Report current {Boot, Valid, Next} systems:
  - Boot: slot from which the software is currently running, or
    'removable' when running off removable media
  - Valid: last validated slot (safe to update from)
  - Next: slot that will boot on the next restart
""".
-callback system_get_systems(State :: term()) ->
    {
        % The system the current software booted from
        BootSysId :: system_id() | removable,
        % The system that is currently validated
        ValidatedSysId :: system_id(),
        % The system that will boot during next restart
        NextSysId :: system_id()
    }.
-doc """
Optionally force which system slot to update and provide its base write
target as #target{}. If you implement this and return {ok, SysId,
SystemTarget}, the manager will skip manifest-structure-based target
selection and use the provided slot/target. If you do NOT implement
this callback, the manager selects the target based on the manifest's
MBR/GPT structure and the current/valid slots. Returning {error, _}
aborts the update (no fallback).
""".
-callback system_get_updatable(State :: term()) ->
    {ok, SysId :: system_id(), SystemTarget :: target()} | {error, Reason :: term}.

-doc """
Called once the update manifest is loaded and before any object is
written. Provides high-level firmware metadata (product, version,
objects, etc.) so the HAL can persist or validate it and keep any data
it needs in its State.
""".
-callback system_update_init(State :: term(), Info :: map()) ->
    {ok, State :: term()} | {error, term()}.
-doc """
Prepare the chosen system slot for update (e.g., unmount filesystem,
ensure not the booted slot). Must not write object data. Return the
updated State or an error to abort.
""".
-callback system_prepare_update(State :: term(), SysId :: system_id()) ->
    {ok, State :: term()} | {error, term()}.
-doc """
Translate an object's target specification into a concrete #target{}
within the selected system target (SysTarget). For example:
  - file_target_spec(context=system): derive the per-slot file path
  - raw_target_spec(context=system): add object offset to system base
If not implemented, the manager provides sensible defaults.
""".
-callback system_prepare_target(State :: term(), SysId :: system_id(),
                                SysTarget :: target(), Spec :: target_spec()) ->
    {ok, Target :: target()}.
-doc """
Record that the target system slot was updated successfully (e.g., set
next-boot slot, write bootloader state) after all objects completed.
Persist changes as needed and return updated State.
""".
-callback system_set_updated(State :: term(), SysId :: system_id()) ->
    {ok, State :: term()} | {error, term()}.
-doc "Roll back any preparation done during an in-progress update (on cancel).".
-callback system_cancel_update(State :: term()) ->
    {ok, State :: term()}.
-doc """
Validate the currently running system (e.g., clear update-pending flag,
commit the active slot). Typically called on first boot after the
update has been applied and verified.
""".
-callback system_validate(State :: term()) ->
    {ok, State :: term()} | {error, term()}.
-doc """
Notified after a single object finished writing. Perform post-write
actions such as sync, metadata updates, or per-object validation.
""".
-callback system_object_updated(State :: term(), Object :: #object{},
                                Target :: #target{}) ->
    {ok, State :: term()} | {error, term()}.
-doc "Called once the entire update succeeded (all objects).".
-callback system_updated(State :: term()) ->
    {ok, State :: term()} | {error, term()}.
-doc "Termination hook for cleanup. Reason indicates shutdown or error cause.".
-callback system_terminate(State :: term(), Reason :: term()) ->
    ok.

-optional_callbacks([system_get_updatable/1, system_prepare_target/4,
                     system_object_updated/3, system_updated/1,
                     system_update_init/2, system_get_global_target/1]).
