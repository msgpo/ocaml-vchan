(* open OS *)

type clisrv = Client | Server

let (>>=) = Lwt.bind

let with_vchan clisrv evtchn_h domid nodepath f =
  (match clisrv with
   | Client ->
     Printf.printf "I'm a client, connecting to domid %d using xs_path %s.\n%!" domid nodepath;
     Vchan.client ~evtchn_h ~domid ~xs_path:nodepath
   | Server ->
     Printf.printf "Initializing Server domid=%d xs_path=%s.\n%!" domid nodepath;
     Vchan.server ~evtchn_h ~domid ~xs_path:nodepath
       ~read_size:5000 ~write_size:5000 ~persist:true)
  >>= fun vch ->
  Printf.printf "Initialization done!\n%!";
  f vch

