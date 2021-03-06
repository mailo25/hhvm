(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

module SMUtils = ServerMonitorUtils

let get_hhserver () =
  let exe_name =
    if Sys.win32 then "hh_server.exe" else "hh_server" in
  let server_next_to_client =
    Path.(to_string @@ concat (dirname executable_name) exe_name) in
  if Sys.file_exists server_next_to_client
  then server_next_to_client
  else exe_name

type env = {
  root: Path.t;
  no_load : bool;
  silent : bool;
  ai_mode : string option;
  debug_port: Unix.file_descr option;
}

let start_server env =
  (* Create a pipe for synchronization with the server: we will wait
     until the server finishes its initialisation phase. *)
  let in_fd, out_fd = Unix.pipe () in
  Unix.set_close_on_exec in_fd;
  let ic = Unix.in_channel_of_descr in_fd in

  let ai_options =
    match env.ai_mode with
    | Some ai -> [| "--ai"; ai |]
    | None -> [||] in  let hh_server = get_hhserver () in
  let hh_server_args =
    Array.concat [
      [|hh_server; "-d"; Path.to_string env.root|];
      if env.no_load then [| "--no-load" |] else [||];
      ai_options;
      (** If the client starts up a server monitor process, the output of that
       * bootup is passed to this FD - so this FD needs to be threaded
       * through the server monitor process then to the typechecker process.
       *
       * Note: Yes, the FD is available in the monitor process as well, but
       * it doesn't, and shouldn't, use it. *)
      [| "--waiting-client"; string_of_int (Handle.get_handle out_fd) |];
      match env.debug_port with
        | None -> [| |]
        | Some fd ->
          [| "--debug-client"; string_of_int @@ Handle.get_handle fd |]
    ] in
  if not env.silent then
    Printf.eprintf "Server launched with the following command:\n\t%s\n%!"
      (String.concat " "
         (Array.to_list (Array.map Filename.quote hh_server_args)));

  try
    let server_pid =
      Unix.(create_process hh_server hh_server_args stdin stdout stderr) in
    Unix.close out_fd;

    match Unix.waitpid [] server_pid with
    | _, Unix.WEXITED 0 ->
      assert (input_line ic = ServerMonitorUtils.ready);
      close_in ic
    | _, Unix.WEXITED i ->
      Printf.eprintf
        "Starting hh_server failed. Exited with status code: %d!\n" i;
      exit 77
    | _ ->
      Printf.eprintf "Could not start hh_server!\n";
      exit 77
  with _ ->
    Printf.eprintf "Could not start hh_server!\n";
    exit 77


let should_start env =
  let root_s = Path.to_string env.root in
  let handoff_options = {
    MonitorRpc.server_name = HhServerMonitorConfig.Program.hh_server;
    force_dormant_start = false;
  } in
  match ServerUtils.connect_to_monitor
    env.root handoff_options with
  | Result.Ok _conn -> false
  | Result.Error
      ( SMUtils.Server_missing
      | SMUtils.Build_id_mismatched _
      | SMUtils.Server_died
      ) -> true
  | Result.Error SMUtils.Server_dormant ->
    Printf.eprintf
      "Server already exists but is dormant";
    false
  | Result.Error SMUtils.Server_busy
  | Result.Error SMUtils.Monitor_connection_failure ->
    Printf.eprintf "Replacing unresponsive server for %s\n%!" root_s;
    ClientStop.kill_server env.root;
    true

let main env =
  HackEventLogger.client_start ();
  if should_start env
  then begin
    start_server env;
    Exit_status.No_error
  end else begin
    Printf.eprintf
      "Error: Server already exists for %s\n\
      Use hh_client restart if you want to kill it and start a new one\n%!"
      (Path.to_string env.root);
    Exit_status.Server_already_exists
  end
