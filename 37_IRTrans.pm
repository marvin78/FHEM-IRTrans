# $Id: 37_IRTrans.pm 1500 2015-09-10 09:31:10Z groeg/marvin78 $

package main;

use strict;
use warnings;
use DevIo;

my %gets = (
   "version:noArg"      => "",
   "remotes"            => "0",
   "commands"           => ""
 
);

sub IRTrans_Initialize($) {
  my ($hash) = @_;

  $hash->{ReadFn}   	= "IRTrans_Read";
  $hash->{SetFn}    	= "IRTrans_Set";
  #$hash->{GetFn}   	 	= "IRTrans_Get";
  $hash->{DefFn}    	= "IRTrans_Define";
  $hash->{NotifyFn} 	= "IRTrans_Notify";
  $hash->{UndefFn}  	= "IRTrans_Undefine";
	$hash->{AttrFn}    	= "IRTrans_Attr";
	$hash->{ReadyFn}  	= "IRTrans_Ready";
	  
  $hash->{AttrList} 	= "disable:1,0 ".
												"do_not_notify:1,0 ".
												$readingFnAttributes;

	return undef;
}

sub IRTrans_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a <= 2) 
  {
		return "Usage: define <name> IRTrans <host> [<port>]";
  }

  my $name = $a[0];
  my $host = $a[2];
  my $port = $a[3] ? $a[3] : 21000;

  $hash->{HOST} = $host;
  $hash->{PORT} = $port;
  $hash->{CONNECTIONSTATE} = "Initialized";

	RemoveInternalTimer($hash);
	
	delete $hash->{helper}{remotes};
	delete $hash->{helper}{commands};
	
	if ($init_done) {
		IRTrans_Disconnect($hash);
		InternalTimer(gettimeofday()+2, "IRTrans_Connect", $hash, 0) if( AttrVal($name, "disable", 0 ) != 1);
	}
	
	$hash->{NOTIFYDEV} 	= "global";
	
  return undef;
}

sub IRTrans_Undefine($$) {
  my ($hash, $arg) = @_;

  RemoveInternalTimer($hash);
	
  IRTrans_Disconnect($hash);
	
  return undef;
}

sub IRTrans_Attr($@) {
  my ($cmd, $name, $attrName, $attrVal) = @_;
	
  my $orig = $attrVal;
	
	my $hash = $defs{$name};
	
	if ( $attrName eq "disable" ) {

		if ( $cmd eq "set" && $attrVal == 1 ) {
			if ($hash->{READINGS}{state}{VAL} eq "connected") {
				RemoveInternalTimer($hash);
				IRTrans_Disconnect($hash);
			}
		}
		elsif ( $cmd eq "del" || $attrVal == 0 ) {
			if ($hash->{READINGS}{state}{VAL} ne "connected") {
				RemoveInternalTimer($hash, "IRTrans_Connect");
				InternalTimer(gettimeofday()+1, "IRTrans_Connect", $hash, 0);
			}
		}
	}
		
	return;
}

sub IRTrans_Notify($$) {
  my ($hash,$dev) = @_;
	
	my $name = $hash->{NAME}; 

  return if($dev->{NAME} ne "global");
	
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  IRTrans_Connect($hash) if( AttrVal($name, "disable", 0 ) != 1);

  return undef;
}

#####################################
# Reconnects IRTrans Interface in case of disconnects
sub IRTrans_Ready($) {
    my ($hash) = @_;
		
		if ($hash->{CONNECTIONSTATE} eq "connected") {
			$hash->{CONNECTIONSTATE} = "disconnected";
			$hash->{LAST_DISCONNECT} = FmtDateTime( gettimeofday() );
		
			readingsSingleUpdate($hash, "state", "disconnected", 1);
		}
   
    return DevIo_OpenDev($hash, 1, "IRTrans_ASCI") if($hash->{STATE} eq "disconnected");
}

sub IRTrans_Read($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  
  if ( AttrVal($name, "disable", 0 ) != 1 ) {
	
		my $buf = DevIo_SimpleRead($hash);
		chomp($buf);		
		
		if(!defined($buf) || length($buf) == 0) {
			DevIo_Disconnected($hash);
			return "";
		}
		
		$hash->{helper}{BUFFER} = $buf;

		my @r = split( " ", $buf);
		my $rbyte = $r[0];
		my $rkey = $r[1];
		my $rres = $r[2];
		
		Log3 $name, 4, "IRTrans ($name): Receiced: ".$rbyte."-".$rkey."-".$rres;
		
		if ($rkey eq "RCV_COM") {
			my @command = split( ",", $rres );
			
			readingsBeginUpdate($hash);
			
			readingsBulkUpdate($hash,"ir_remote_received",$command[0]);
			readingsBulkUpdate($hash,"ir_cmd_received",$command[1]);
			readingsBulkUpdate($hash,"bus",$command[2]);
			readingsBulkUpdate($hash,"devId",$command[3]);
			readingsBulkUpdate($hash,"ir_receive_type","cmd");
			
			readingsEndUpdate($hash, 1);
			
		}
		
		elsif ($rkey eq "VERSION") {
			my $rsonst = $r[3];
			readingsBeginUpdate($hash);
			
			readingsBulkUpdate($hash,"version",$rres." ".$rsonst);
			readingsBulkUpdate($hash,"ir_receive_type","version");
			
			readingsEndUpdate($hash, 1);
			
			$hash->{VERSION}=$rres." ".$rsonst;
		}
		
		elsif ($rkey eq "REMOTELIST") {
			my @list = split( ",", $rres);
			my $offset = $list[0];
			my $count = $list[1];
			my $remote = "";
			my $i=0;
			my $r=0;
			
			foreach my $li (@list) {
				
				if ($i>2) {
									
					$r=$i-2+$offset;
					$remote.=$li." ";
					
					$hash->{helper}{remotes}[$r-1] = $li;
					$hash->{helper}{remotesH}[$r-1] = $li;
				}
				$i++;
			}
			
			my $nHash;
			$nHash->{HASH} = $hash;
			
			if ($r<$count) {
			
				$nHash->{FBNR} = $r;
				RemoveInternalTimer($nHash, "IRTrans_GetRemotes");
				InternalTimer(gettimeofday()+1, "IRTrans_GetRemotes", $nHash, 0);
				
			}
			else {
				$nHash->{FB} = "none";
				RemoveInternalTimer($nHash, "IRTrans_GetCommands");
				InternalTimer(gettimeofday()+2, "IRTrans_GetCommands", $nHash, 0);
			}

			readingsBeginUpdate($hash);
			
			readingsBulkUpdate($hash,"ir_remotes",$remote);
			readingsBulkUpdate($hash,"ir_receive_type","remotelist");
			
			readingsEndUpdate($hash, 1);
		}
		elsif ($rkey eq "COMMANDLIST") {
		
			my @list = split( ",", $rres);
			my $offset = $list[0];
			my $count = $list[1];
			my $remote = "";
			my $i=0;
			my $r=0;
			
			my $next=$count-12;
			
			foreach my $li (@list) {
				$li =~ s/^\s+|\s+$//g;
				if ($i>2) {
					$r=$i-2+$offset;
					$remote.=$li." ";
				
					$hash->{helper}{commands}{$hash->{helper}{LAST_FB}}[$r-1]=$li;
					
				}
				
				$i++;
			}
			
			my $nHash;
			$nHash->{HASH}=$hash;
			
			if ($r<$count) {
			
				$nHash->{FB} = $hash->{helper}{LAST_FB}.",$r";
				RemoveInternalTimer($nHash, "IRTrans_GetCommands");
				InternalTimer(gettimeofday()+1, "IRTrans_GetCommands", $nHash, 0);
				
			}
			else {
				my $v=0;
				
				shift(@{ $hash->{helper}{remotesH} });
				
				if ($hash->{helper}{remotesH}[0] ) {
					$nHash->{FB}=$hash->{helper}{remotesH}[0];
					RemoveInternalTimer($nHash, "IRTrans_GetCommands");
					InternalTimer(gettimeofday()+1, "IRTrans_GetCommands", $nHash, 0);
				}
				else {
					RemoveInternalTimer($nHash);
					delete $hash->{helper}{remotesH};
				}
			}

			readingsSingleUpdate($hash,"ir_receive_type","commandlist",1);
			
		}

		readingsSingleUpdate($hash,"last_result",$buf,1);

	}
	return undef;
}

sub IRTrans_Set($@) {
  my ($hash, @a) = @_;
  my ($name,$cmd,$remote,$irCmd)=@a;
	
	my @sets = ();
	
	push @sets, "connect" if ($hash->{READINGS}{state}{VAL} eq "disconnected" && AttrVal($name, "disable", 0 ) != 1);
	push @sets, "disconnect" if ($hash->{READINGS}{state}{VAL} eq "connected" || AttrVal($name, "disable", 0 ) == 1);
	push @sets, "reconnect" if (AttrVal($name, "disable", 0 ) != 1 && $hash->{READINGS}{state}{VAL} eq "connected");
	push @sets, "irSend" if (AttrVal($name, "disable", 0 ) != 1 && $hash->{READINGS}{state}{VAL} eq "connected");
	
	if ($hash->{helper}{remotes} && ref( $hash->{helper}{remotes} ) eq "ARRAY" && $hash->{helper}{commands} && AttrVal($name, "disable", 0 ) != 1 && $hash->{READINGS}{state}{VAL} eq "connected") {
		my $remotes;
		my $commands;
		
		$remotes .= join( ',', @{ $hash->{helper}{remotes} } );
		
		my $r=0;
		foreach my $remote (@{ $hash->{helper}{remotes} } ) {
			my $remText;
			my $i=0;
			if (ref( $hash->{helper}{commands}{$remote}  ) eq "ARRAY") {
				$r++;
				
				foreach my $command (@{ $hash->{helper}{commands}{$remote} }) {
					$i++;
					$remText .= "," if ($i!=1);
					$remText .= $command;
				}
			}
			push @sets, "$remote:$remText" if ($remote && $remText);
		}
	}
	
  return join(" ", @sets) if ($cmd eq "?");
	
	return "$name is disabled. Enable it to use set IRTrans [...]" if( AttrVal($name, "disable", 0 ) == 1 );
  
  if ( $cmd eq "disconnect") {
    IRTrans_Disconnect($hash);
  }
  elsif ( $cmd eq "connect") {
    IRTrans_Connect($hash);
  }
  elsif ( $cmd eq "reconnect") {
    IRTrans_reConnect($hash);
  }
  elsif (( $cmd eq "irSend") and (defined $remote and length $remote) and (defined $irCmd and length $irCmd)) {
		readingsBeginUpdate($hash);
			
		readingsBulkUpdate($hash,"ir_remote_sent",$remote);
		readingsBulkUpdate($hash,"ir_cmd_sent",$irCmd);
			
		readingsEndUpdate($hash, 1);
			
    my $data = "Asnd ".$remote.",".$irCmd."\r\n";
    IRTrans_send($hash,$data);
  }
	elsif (grep $_ eq $cmd,@{ $hash->{helper}{remotes} } and (defined $remote and length $remote)) {
		readingsBeginUpdate($hash);
			
		readingsBulkUpdate($hash,"ir_remote_sent",$cmd);
		readingsBulkUpdate($hash,"ir_cmd_sent",$remote);
			
		readingsEndUpdate($hash, 1);
		
		my $data = "Asnd ".$cmd.",".$remote."\r\n";
    IRTrans_send($hash,$data);
	}
  else {
    return "Command or parameter not available!";
  }
	
	return;
}

sub IRTrans_Get($@) {
  my ($hash, @a) = @_;
  my ($name,$cmd,$cmd2,$cmd3)=@a;
  my $ret = undef;
  
  if ( $cmd eq "version") {
    IRTrans_send($hash,"Aver\r\n");
  }
  elsif ( $cmd eq "remotes" && $cmd2 >= 0) {
    IRTrans_send($hash,"Agetremotes $cmd2\r\n");
  }
  elsif ( $cmd eq "commands" && $cmd2 ne 0) {
		my @cmds = split(",",$cmd2);
		$hash->{helper}{LAST_FB}=$cmds[0];
    IRTrans_send($hash,"Agetcommands $cmd2\r\n");
  }
  else {
    $ret ="$name get with unknown argument $cmd, choose one of " . join(" ", sort keys %gets);
  }
  
  return $ret;
}


#####################################
# Connects to the IRTrans
sub IRTrans_Connect($) {
	my ($hash) = @_;
	my $name = $hash->{NAME}; 
		
	my $ret;
	
	DevIo_CloseDev($hash);
	
	if( AttrVal($name, "disable", 0 ) != 1 ) {
		
		$hash->{DeviceName} = $hash->{HOST}.":".$hash->{PORT};
		
		$ret=DevIo_OpenDev($hash, 0, "IRTrans_ASCI");	
					
		Log3 $name, 4, "IRTrans ($name): connected to $hash->{HOST}:$hash->{PORT}";	
		
	}
	else {
		Log3 $name, 4, "AsteriskCM ($name): Device is disabled. Could not connect.";
	}
	
	return $ret;
}

#####################################
# Disconnects from IRTrans
sub IRTrans_Disconnect($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
	

	RemoveInternalTimer($hash);
	
	readingsSingleUpdate($hash, "state", "disconnected", 1);
	  
	DevIo_CloseDev($hash);	
	
	$hash->{CONNECTIONSTATE} = "disconnected";
	$hash->{LAST_DISCONNECT} = FmtDateTime( gettimeofday() );
	
	Log3 $name, 3, "IRTrans ($name): Disonnected";
	
	return undef;
}

sub IRTrans_reConnect($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "IRTrans ($name): reconnect";

  IRTrans_Disconnect($hash);
  InternalTimer(gettimeofday()+1, "IRTrans_Connect", $hash, 0) if( AttrVal($name, "disable", 0 ) != 1 );
}

#####################################
# Sends ASCI to IRTrans
sub IRTrans_ASCI ($) {
	my ($hash) = @_;
	my $name = $hash->{NAME}; 
	
	$hash->{CONNECTIONSTATE} = "connected";
	$hash->{CONNECTS}++;
	$hash->{LAST_CONNECT} = FmtDateTime( gettimeofday() );
	
	my $nHash;
	$nHash->{HASH}=$hash;
	
	DevIo_SimpleWrite($hash,"ASCI",0);
	
	Log3 $name, 4, "IRTrans ($name): Sent ASCI to IRTrans Device.";
	
	readingsSingleUpdate($hash,"state","connected",1);
	
	$nHash->{FBNR} = 0;
	
	RemoveInternalTimer($hash, "IRTrans_GetVersion");
	RemoveInternalTimer($nHash, "IRTrans_GetRemotes");
	
	InternalTimer(gettimeofday()+1, "IRTrans_GetVersion", $hash, 0);
	InternalTimer(gettimeofday()+2, "IRTrans_GetRemotes", $nHash, 0);
	
	return undef;
}

sub IRTrans_GetRemotes ($) {
	my ($nHash)=@_;
	my @a;
	
	my $hash = $nHash->{HASH};
	my $name = $hash->{NAME}; 
	
	my $nr=$nHash->{FBNR};
	
	IRTrans_send($hash,"Agetremotes $nr\r\n");
	
	Log3 $name, 4, "IRTrans ($name): Sent remotes to IRTRans Device to get remotes back.";
	
	return undef;
}

sub IRTrans_GetCommands ($) {
	my ($nHash)=@_;
	my @a;
	
	my $hash = $nHash->{HASH};
	my $name = $hash->{NAME}; 
	
	$nHash->{FB}=$hash->{helper}{remotesH}[0] if ($nHash->{FB} eq "none");
	
	my $fb=$nHash->{FB};
	
	my @fbs = split(",",$fb);
	$hash->{helper}{LAST_FB}=$fbs[0];
	
	IRTrans_send($hash,"Agetcommands $fb\r\n");
	
	Log3 $name, 4, "IRTrans ($name): Get commands for $fb.";
	
	return undef;
}

sub IRTrans_GetVersion($) {
	my ($hash)=@_;
	my @a;
	my $name = $hash->{NAME}; 
	
	$a[0]=$hash->{NAME};
	$a[1]="version";
	
	IRTrans_Get($hash,@a);
	
	Log3 $name, 4, "IRTrans ($name): Sent version to IRTRans Device.";
	
	return undef;
}

sub IRTrans_send($$) {
  my ($hash, $data) = @_;
  my $name = $hash->{NAME};
	
	DevIo_SimpleWrite($hash,$data,0);
	
	Log3 $name, 4, "IRTrans ($name): sent $data";
  
  return undef;
}

1;

=pod
=begin html

<a name="IRTrans"></a>
<h3>IRTrans</h3>
<ul>
  Defines a device to integrate an IRTrans-Device. It's possible to receive an send IR commands.<br /><br />

  <a name="IRTrans_Define"></a>
  <b>Define</b><br />
  <ul>
    <code>define &lt;name&gt; IRTrans &lt;ip&gt; [&lt;port&gt;]</code><br />
    <br />

    Defines a IRTrans device. Default port is 21000. Saved remotes and corresponding commands are read automatically from the IRTrans-Device.<br /><br />

    Example:
    <ul>
      <code>define irdev IRTrans 192.168.2.10 21000</code><br />
    </ul>
  </ul><br />
	
	<a name="IRTrans_Attributes"></a>
  <b>Attributes</b><br />
  <ul>
		<li><a href="#readingFnAttributes">readingFnAttributes</a></li><br />
		<li><a href="#do_not_notify">do_not_notify</a></li><br />
    <li><a name="disable">disable</a></li>
	</ul><br />
    
  <a name="IRTrans_Readings"></a>
  <b>Readings</b><br />
  <ul>
		<li>bus<br />
      Bus ID (always 0 with Ethernet modules).</li><br />
		<li>devId<br />
      IRTrans Bus Device ID (always 0 without bus modules).</li><br />
		<li>ir_cmd_received<br />
      The name of the last database command received from IRTrans device.</li><br />
		<li>ir_cmd_sent<br />
      The last command sent to the IRTrans device.</li><br />
    <li>ir_remote_received<br />
      The name of the remote in the database (used for last received command).</li><br />
    <li>ir_receive_type<br />
      The last received action type.</li><br />
		<li>ir_remote_sent<br />
      The last remote used to send a command with by the IRTrans device.</li><br />
		<li>ir_remotes<br />
      List of remotes in the database.</li><br />
		<li>last_result<br />
      The last result received from the IRTrans device.</li><br />
		<li>state<br />
      The state of the FHEM IRTrans-device (opened/connected/disconnected).</li><br />
    <li>version<br />
      the Version of the used IRTrans Device.</li><br />
  </ul><br />

  <a name="IRTrans_Set"></a>
  <b>Set</b><br />
  <ul>
    <li>connect<br />
      connect to IRTrans Device (only available if device is not diabled)</li><br />
    <li>disconnect<br />
      disconnect from IRTrans Device (only available if device is connected)</li><br />
    <li>reconnect<br />
      reconnect to IRTrans Device (only available if device is connected)</li><br />
    <li>irSend &lt;remote&gt; &lt;command&gt;<br />
      send the given ir command for the remote (only available if device is connected)</li><br />
		<li>&lt;remote&gt; &lt;command&gt;<br />
      send the given ir command for the remote (only available if device is connected and if remotes are loaded from IRTrans database)</li><br />
  </ul><br />
</ul>

=end html
=cut
