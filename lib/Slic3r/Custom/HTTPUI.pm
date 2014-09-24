package Slic3r::Custom::HTTPUI;

use strict;
use warnings;
use CGI qw/ :standard /;
use HTTP::Daemon;
use HTTP::Response;
use HTTP::Status;
use URI;
use URI::QueryParam;
use Slic3r::Model;
use Slic3r::Config;
use threads;
use utf8;
use JSON;
use File::Basename qw(basename);
use Slic3r::Geometry qw(X Y Z);

use constant CONFIG_HTTP	=> "config_http.ini";

use constant CONFIG_SLICER		=> "config.ini";
use constant OUTPUT_GCODE		=> "_sliced_model.gcode";
use constant OUTPUT_PREVIEW		=> "preview.png";
use constant FILE_STATUS		=> "Slicer.json";
use constant FILE_PERCENTAGE	=> "Percentage.json";
use constant NUMBER_EXTRUDER	=> 2;
use constant HEIGHT_PLATFORM	=> 150;

use constant CURRENT_VERSION	=> "1.0";

my $css = <<CSS;
		form { display: inline; }
CSS

our $Config;

sub new {
	my $class = shift;
	my $config = shift;
	my $self;
	
	# pass config to this class to avoid using the default settings - peng
	$self->{config_slic3r} = $config;
	
	$self->{have_threads} = $Slic3r::have_threads;
	$Slic3r::have_threads = 0;
	
	$self->{d} = HTTP::Daemon->new(
			LocalAddr => 'localhost', # '0.0.0.0' for all access
			LocalPort => 8080) || die;
	
	$self->{model} = undef;
	$self->{thread} = undef;
	
	# Config file under the root
	$self->{config} = Slic3r::Config->read_ini(CONFIG_HTTP);
	unless (exists($self->{config}->{http}{systemconf}) && 
			exists($self->{config}->{http}{sdconf}) &&
			exists($self->{config}->{http}{conf}) &&
			exists($self->{config}->{http}{model}) &&
			exists($self->{config}->{http}{preview})) {
		die "Incorrect or missing config file\n";
	}
	
	bless $self, $class;
	
	return $self;
}


##		threads->create(\&process_client_requests, $self, $c)->detach;
#		process_client_requests($self, $c);


sub main_loop {
	my $self = shift;
	
	# initialise status and other file if not in latest version
	_init_file();
	print "Start listening request...\n";
	
	while (my $c = $self->{d}->accept) {
		
#		$c->daemon->close;   # close server socket in client (http://mrajcok.wordpress.com/2011/08/20/78/ ???)
#		May be some kind of missunderstanding here...
		
		while(my $r = $c->get_request) {
			
			my %FORM = $r->uri->query_form();
			
			if ($r->method eq 'GET') {
				if ($r->uri->path eq "/shutdown") {
#					Shutdown
					
					_http_response_text($c, 200, 'Ok');
					$c->close;
					undef($c);
					return;
				} elsif ($r->uri->path eq "/reload") {
#					Reload config from INI
					
					reload_config($self, $r, $c);
				} elsif ($r->uri->path eq "/add") {
#					Add objet (can't be interrupted)
					
					add_file($self, $r, $c);
				} elsif ($r->uri->path eq "/addstatus") {
#					Check add status
					
					check_add($self, $r, $c);
				} elsif ($r->uri->path eq "/slice") {
#					Slicing (interruptible)
					
					slice($self, $r, $c);
				} elsif ($r->uri->path eq "/slicehalt") {
#					Interrupt slincing
					
					slice_halt($self, $r, $c);
				} elsif ($r->uri->path eq "/listmodel") {
#					List of models
					
					list_model($self, $r, $c);
				} elsif ($r->uri->path eq "/removemodel") {
#					Remove model by ID
					
					remove_model($self, $r, $c);
				} elsif ($r->uri->path eq "/getmodel") {
#					Get model filepath by ID
					
					get_model($self, $r, $c);
				} elsif ($r->uri->path eq "/setmodel") {
#					Set model filepath by ID
					
					set_model($self, $r, $c);
				} elsif ($r->uri->path eq "/preview") {
#					Rendering model preview (can't be interrupted)
					
					preview_model($self, $r, $c);
				} elsif ($r->uri->path eq "/slicestatus") {
#					Check slicing status
					
					check_slice($self, $r, $c);
				} elsif ($r->uri->path eq "/setparameter") {
#					Set temporary parameters
					
					set_parameter($self, $r, $c);
				} elsif ($r->uri->path eq "/test") {
#					Test method
					
					test_function($self, $r, $c);
				} else {
#					Splash screen...
					
					_http_response_text($c, 200, 'Slic3r 1.00RC1 - HTTP daemon Zeepro mod');
				}
			} elsif ($r->method eq 'POST') {
				if ($r->uri->path eq "/loadmodel") {
					my $uri = URI->new();
					$uri->query($r->content);
					my %params = $uri->query_form;
					_http_response($c, { content_type => 'text/plain'}, 'Ok');
				} else {
					$c->send_error(RC_FORBIDDEN);
				} 
			} else {
				$c->send_error(RC_FORBIDDEN);
			}
		}
		$c->close;
		undef($c);
	}
}

sub add_file {
	my ($self, $r, $c) = @_;
	print "Request: add_file\n";
	
	if (!$r->uri->query_param("file")) {
		_http_response_text($c, 432, 'Missing parameter');
	} else {
		_save_status($self, "Working", $r->uri->as_string);
		
		eval {
			my $input_file = $r->uri->query_param("file");
			my $number_material = 0;
			my $ref_array_file;
			my @array_file;
			my $number_file = 0;
			
			if (defined($input_file)) {
				$ref_array_file = decode_json $input_file;
			}
			@array_file = @{$ref_array_file};
			$number_file = scalar @array_file;
			
			foreach my $file (@array_file) {
				unless ( -e $file ) {
					die("File not exists: " . $file);
				}
			}
			
			if ($number_file <= 0) {
				die("No input file detected");
			}
			elsif ($number_file == 1) {
				$self->{model} = Slic3r::Model->read_from_file($array_file[0]);
			}
			else {
				my @models = map {Slic3r::Model->read_from_file($_)} @array_file;
				$self->{model} = Slic3r::Model->new;
				my $new_object = $self->{model}->add_object;
				for my $m (0 .. $#models) {
					my $model = $models[$m];
					$self->{model}->set_material($m, { Name => basename($model->{objects}->[0]->{input_file}) });
					$new_object->add_volume(
						material_id	=> $m,
						mesh		=> $model->objects->[0]->volumes->[0]->mesh,
					);
				}
				$new_object->{input_file} = $models[0]->{objects}->[0]->{input_file};
			}
			
			$_->scale($self->{config_slic3r}->scale) for @{$self->{model}->objects};
			$number_material = scalar keys( %{$self->{model}->{materials}} );
			if ($number_material == 0) {
				$self->{model}->set_material(0, {Name => basename($self->{model}->{objects}[0]->{input_file})});
				$self->{model}->{objects}->[0]->{volumes}->[0]->{material_id} = 0;
				print "init material, extruder\n";
			}
			elsif ($number_material > 2) {
				die("Model more than 2 materials");
			}
			foreach my $key (keys $self->{model}->{objects}->[0]->{volumes}) {
				$self->{model}->{objects}->[0]->{material_mapping}{$key} = $key + 1;
			}
			$self->{model}->arrange_objects($self->{config_slic3r});
			
			$self->{model}->print_info; #test
			
			1;
		};
		if ($@) {
			_http_response_text($c, 433, $@);
		} else {
			_http_response_text($c, 200, 'Ok');
		}
		
		_save_status($self, "Done", $r->uri->as_string);
	}
	
	return;
}

sub list_model {
	my ($self, $r, $c) = @_;
	print "Request: list_model\n";
	
	my @array_json;
	my $id_object = -1;
	
	foreach my $object (@{$self->{model}->{objects}}) {
		$id_object++;
		my %hash_data = _model_info($self, $object);
		$hash_data{id} = $id_object;
		push(@array_json, \%hash_data);
	}
	
	_http_response_text($c, 200, to_json(\@array_json));
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub remove_model {
	my ($self, $r, $c) = @_;
	print "Request: remove_model\n";
	
	unless (defined($r->uri->query_param("id"))) {
		_http_response_text($c, 432, 'Missing parameter');
	} else {
		my $model_id = $r->uri->query_param("id");
		if (defined($self->{model}->{objects}[$model_id])) {
			splice ($self->{model}->{objects}, $model_id, 1);
			if (scalar @{$self->{model}->{objects}}) {
				$self->{model}->arrange_objects($self->{config_slic3r});
			}
			_http_response_text($c, 200, 'Ok');
		} else {
			_http_response_text($c, 433, 'Incorrect parameter');
		}
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub get_model {
	my ($self, $r, $c) = @_;
	print "Request: get_model\n";
	
	unless (defined($self->{model})) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		unless (defined($r->uri->query_param("id"))) {
			_http_response_text($c, 432, 'Missing parameter');
		} else {
			my $model_id = $r->uri->query_param("id");
			if (defined($self->{model}->{objects}[$model_id])) {
				_http_response_text($c, 200, $self->{model}->{objects}[$model_id]->{input_file});
			} else {
				_http_response_text($c, 433, 'Incorrect parameter');
			}
		}
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub set_model {
	my ($self, $r, $c) = @_;
	print "Request: set_model\n";
	
	unless (defined($self->{model})) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		unless (defined($r->uri->query_param("id"))) {
			_http_response_text($c, 432, 'Missing parameter');
		}
		unless (defined($r->uri->query_param("xpos"))
				|| defined($r->uri->query_param("ypos"))
				|| defined($r->uri->query_param("zpos"))
				|| defined($r->uri->query_param("xrot"))
				|| defined($r->uri->query_param("yrot"))
				|| defined($r->uri->query_param("zrot"))
				|| defined($r->uri->query_param("s")) #scale
				|| defined($r->uri->query_param("c")) #color
				) {
			_http_response_text($c, 432, 'Missing parameter');
		} else {
			my $model_id = $r->uri->query_param("id");
			my $xpos = $r->uri->query_param("xpos"); # no use for one model
			my $ypos = $r->uri->query_param("ypos"); # no use for one model
			my $zpos = $r->uri->query_param("zpos"); # no sense
			my $xrot = $r->uri->query_param("xrot");
			my $yrot = $r->uri->query_param("yrot");
			my $zrot = $r->uri->query_param("zrot");
			my $scale = $r->uri->query_param("s"); 
			my $color = $r->uri->query_param("c");
			if (defined($self->{model}->{objects}[$model_id])) {
				eval {
					my $object = $self->{model}->{objects}[$model_id];
					if (defined($color)) {
						my $array_color = decode_json($color);
						my $nb_color = scalar @{$array_color};
						my $nb_volume = scalar keys( %{$object->{material_mapping}} );
						if ($nb_color != $nb_volume) {
							die("Incorrect color");
						}
						
						my $id_volume = 0;
						foreach my $ele_color (@{$array_color}) {
							$object->{material_mapping}{$id_volume} = int $ele_color;
							++$id_volume;
						}
					}
					
					#TODO do some more intelligent action here for rotation
					my %hash_data = _model_info($self, $object);
					my $scale_ori = $hash_data{s} / 100;
					my $zrot_ori = $hash_data{zrot} * 1;
					my $xrot_ori = $hash_data{xrot} * 1;
					my $yrot_ori = $hash_data{yrot} * 1;
					my $need_rotation = 0;
					if (defined($scale)) {
						$scale /= 100; # percentage to real
						print "scale: " . $scale_ori . "=>" . $scale . "\n";
						$object->scale($scale / $scale_ori);
						$object->{instances}[0]->{scaling_factor} = $scale;
					}
					if (defined($zrot)) {
						$zrot *= 1;
						print "rotZ: " . $zrot_ori . "=>" . $zrot . "\n";
						if ($zrot != $zrot_ori) {
							++$need_rotation;
						}
					}
					if (defined($xrot)) {
						$xrot *= 1;
						print "rotX: " . $xrot_ori . "=>" . $xrot . "\n";
						if ($xrot != $xrot_ori) {
							++$need_rotation;
						}
					}
					if (defined($yrot)) {
						$yrot *= 1;
						print "rotY: " . $yrot_ori . "=>" . $yrot . "\n";
						if ($yrot != $yrot_ori) {
							++$need_rotation;
						}
					}
					
					if ($need_rotation > 0) {
						# recover the orginal status
						$object->rotateY(-$yrot_ori);
						$object->rotateX(-$xrot_ori);
						$object->rotate(-$zrot_ori);
						
						if (defined($zrot)) {
							$object->rotate($zrot);
							$object->{instances}[0]->{rotation} = $zrot;
						}
						else {
							$object->rotate($zrot_ori);
						}
						if (defined($xrot)) {
							$object->rotateX($xrot);
							$object->{instances}[0]->{rotationX} = $xrot;
						}
						else {
							$object->rotateX($xrot_ori);
						}
						if (defined($yrot)) {
							$object->rotateY($yrot);
							$object->{instances}[0]->{rotationY} = $yrot;
						}
						else {
							$object->rotateY($yrot_ori);
						}
					}
					
					my $bed_size = $self->{config_slic3r}->get("bed_size");
					%hash_data = _model_info($self, $object);
					if ($hash_data{xpos} < 0 || $hash_data{xmax} > $bed_size->[X]
							|| $hash_data{ypos} < 0 || $hash_data{ymax} > $bed_size->[Y]
							|| $hash_data{zpos} < 0 || $hash_data{zmax} > HEIGHT_PLATFORM
							) {
						# return to original status if error
						if (defined($scale)) {
							$object->scale($scale_ori / $scale);
							$object->{instances}[0]->{scaling_factor} = $scale_ori;
						}
						if ($need_rotation > 0) {
							if (defined($yrot)) {
								$object->rotateY(-$yrot);
							}
							else {
								$object->rotateY(-$yrot_ori);
							}
							if (defined($xrot)) {
								$object->rotateX(-$xrot);
							}
							else {
								$object->rotateX(-$xrot_ori);
							}
							if (defined($zrot)) {
								$object->rotate(-$zrot);
							}
							else {
								$object->rotate(-$zrot_ori);
							}
							$object->rotate($zrot_ori);
							$object->{instances}[0]->{rotation} = $zrot_ori;
							$object->rotateX($xrot_ori);
							$object->{instances}[0]->{rotationX} = $xrot_ori;
							$object->rotateY($yrot_ori);
							$object->{instances}[0]->{rotationY} = $yrot_ori;
						}
						
						die("Incorrect setting to overload platform");
					}
					
					$object->align_to_origin;
					
					1;
				};
				if ($@) {
					print "ErrMsg: " . $@ . "\n";
					_http_response_text($c, 433, $@);
				} else {
					_http_response_text($c, 200, 'Ok');
				}
				
				_http_response_text($c, 200, 'Ok');
				
				$self->{model}->print_info; #test
			} else {
				_http_response_text($c, 433, 'Incorrect parameter');
			}
		}
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub set_parameter {
	my ($self, $r, $c) = @_;
	print "Request: set_parameter\n";
	
	unless (defined($r->uri->query_param("temperature"))
	 || defined($r->uri->query_param("first_layer_temperature"))
	 || defined($r->uri->query_param("fill_density"))
	 || defined($r->uri->query_param("skirts"))
	 || defined($r->uri->query_param("raft_layers"))
	 || defined($r->uri->query_param("support_material"))) {
		_http_response_text($c, 432, 'Missing parameter');
	}
	else {
		if (defined($r->uri->query_param("fill_density"))) {
			$self->{config_slic3r}->set("fill_density", $r->uri->query_param("fill_density"), 1);
			print "set fill_density " . $self->{config_slic3r}->get("fill_density") . "\n";
		}
		if (defined($r->uri->query_param("skirts"))) {
			$self->{config_slic3r}->set("skirts", $r->uri->query_param("skirts"), 1);
			print "set skirts " . $self->{config_slic3r}->get("skirts") . "\n";
		}
		if (defined($r->uri->query_param("raft_layers"))) {
			$self->{config_slic3r}->set("raft_layers", $r->uri->query_param("raft_layers"), 1);
			print "set raft_layers " . $self->{config_slic3r}->get("raft_layers") . "\n";
		}
		if (defined($r->uri->query_param("support_material"))) {
			$self->{config_slic3r}->set("support_material", $r->uri->query_param("support_material"), 1);
			print "set support_material " . $self->{config_slic3r}->get("support_material") . "\n";
		}
		if (defined($r->uri->query_param("temperature"))) {
			$self->{config_slic3r}->set("temperature", $r->uri->query_param("temperature"), 1);
			print "set temperature " . $self->{config_slic3r}->serialize("temperature") . "\n";
		}
		if (defined($r->uri->query_param("first_layer_temperature"))) {
			$self->{config_slic3r}->set("first_layer_temperature", $r->uri->query_param("first_layer_temperature"), 1);
			print "set first_layer_temperature " . $self->{config_slic3r}->serialize("first_layer_temperature") . "\n";
		}
		
		_http_response_text($c, 200, 'Ok');
	}
	
	return;
}

sub preview_model {
	my ($self, $r, $c) = @_;
	print "Request: preview_model\n";
	
	# only rendering the first object of model
	unless (defined($r->uri->query_param("rho"))
	 && defined($r->uri->query_param("theta"))
	 && defined($r->uri->query_param("delta"))) {
		_http_response_text($c, 432, 'Missing parameter');
		
		return;
	}
	
	unless (defined($self->{model})) {
		_http_response_text($c, 453, 'No model in system');
		
		return;
	}
	
	_save_status($self, "Working", $r->uri->as_string);
	
	eval {
		require Slic3r::Custom::Preview;
		my $input_rho = $r->uri->query_param("rho");
		if ($input_rho > 5000) { #check rho to be a useful value
			die "rho is too big!";
		}
		
		my $input_theta = $r->uri->query_param("theta");
		my $input_delta = $r->uri->query_param("delta") - 90;
		my $image_file = $self->{config}->{http}{preview} . OUTPUT_PREVIEW;
		my $object = $self->{model}->{objects}[0];
		my $input_color1 = $r->uri->query_param("color1") // undef;
		my $input_color2 = $r->uri->query_param("color2") // undef;
		my ($data_color1, $data_color2);
		if (defined($input_color1)) {
			$data_color1 = decode_json($input_color1);
		}
		else {
			$data_color1 = undef;
		}
		if (defined($input_color2)) {
			$data_color2 = decode_json($input_color2);
		}
		else {
			$data_color2 = undef;
		}
		
#		print Dumper($data_color1);
#		print Dumper($data_color2);
		
		my $object_preview = Slic3r::Custom::Preview->new(
			$object, $input_rho, $input_theta, $input_delta, $image_file,
			$data_color1, $data_color2);
		$object_preview->InitBuffer();
		$object_preview->Resize();
		$object_preview->Render();
		$object_preview->ReleaseRessource();
		
		1;
	};
	if ($@) {
		_http_response_text($c, 433, $@);
	} else {
		_http_response_text($c, 200, 'Ok' . "\n" . $self->{config}->{http}{preview} . OUTPUT_PREVIEW);
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub reload_config {
	my ($self, $r, $c) = @_;
	print "Request: reload_config\n";
	
	my @external_configs = ();
	my $configfile;
	my $sdcard = $r->uri->query_param("sdcard") // undef;
	
	if (defined($sdcard)) {
		$configfile = $self->{config}->{http}{sdconf} . CONFIG_SLICER;
	} else {
		$configfile = $self->{config}->{http}{systemconf} . CONFIG_SLICER;
	}
	
	if (-e $configfile) {
		push @external_configs, Slic3r::Config->load($configfile);
		$self->{config_slic3r}->apply($_) for @external_configs;
		_http_response_text($c, 200, 'Ok');
	} else {
		_http_response_text($c, 500, 'cannot find config file');
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub slice {
	my ($self, $r, $c) = @_;
	print "Request: slice\n";
	
	_save_status_pHalt($self, "Working", $r->uri->as_string, "/slicehalt");
	
	unless (defined($self->{model}) && scalar @{$self->{model}->{objects}} > 0) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		if ($self->{have_threads}) { #TODO better check if we are in slicing or not
			$self->{thread} = threads->create(\&_go_slice, $self, $r->uri->as_string);
		} else {
			_go_slice($self, $r->uri->as_string);
		}
		_http_response_text($c, 200, 'Ok');
	}
	
	
	return;
}

sub slice_halt {
	my ($self, $r, $c) = @_;
	print "Request: slice_halt\n";

	if ($self->{have_threads}) {
		if ($self->{thread}) {
			$self->{thread}->kill('KILL')->join();
			$self->{thread} = undef;
			_http_response_text($c, 200, 'Ok');
		} else {
			_http_response_text($c, 437, 'No current slicing');
		}
	} else {
		_http_response_text($c, 499, 'Ok');
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub check_slice {
	my ($self, $r, $c) = @_;
	print "Request: check_slice\n";
	
	unless( -e ($self->{config}->{http}{conf} . FILE_PERCENTAGE) ) {
		my $data = _load_JSON($self, FILE_STATUS);
		if (!defined($data)) {
			_http_response_text($c, 500, "cannot open status file");
		} elsif ($data->{Sate} eq "Error") {
			_http_response_text($c, 499, $data->{Message});
		} else {
			_http_response_text($c, 200, -1);
		}
	} else {
		my $data = _load_JSON($self, FILE_PERCENTAGE);
		if (!defined($data)) {
			_http_response_text($c, 500, "cannot open percentage file");
		} elsif ($data->{percent} == 100) {
			_http_response_text($c, 200, $data->{percent} . "\n" . $data->{message});
			unlink($self->{config}->{http}{conf} . FILE_PERCENTAGE);
		} else {
			_http_response_text($c, 200, $data->{percent});
		}
	}
	
	return;
}

sub test_function {
	my ($self, $r, $c) = @_;
	print "Request: test_function\n";
	
	my $data = _load_JSON($self, FILE_STATUS);
	
	return;
}

sub _init_file {
	#TODO check conf file version
}

sub _model_info {
	my ($self, $object) = @_;
	
	my $center = $object->center;
	my $size = $object->bounding_box->size;
	my $instance = $object->{instances}[0];
	my ($xpos, $ypos, $xcen, $ycen, $xmax, $ymax);
	my @array_color;
	my %hash_data;
	
	foreach my $name (sort keys $object->{material_mapping}) {
		push (@array_color, $object->{material_mapping}{$name});
	}
	$xcen = $self->{config_slic3r}->{print_center}[X] + $instance->{offset}[X];
	$ycen = $self->{config_slic3r}->{print_center}[Y] + $instance->{offset}[Y];
	$xpos = $xcen - $size->[X] / 2;
	$ypos = $ycen - $size->[Y] / 2;
	$xmax = $xcen + $size->[X] / 2;
	$ymax = $ycen + $size->[Y] / 2;
	%hash_data = (
			"xpos"	=> $xpos,
			"ypos"	=> $ypos,
			"zpos"	=> 0, #TODO deal it with model
			"xcen"	=> $xcen,
			"ycen"	=> $ycen,
			"xmax"	=> $xmax,
			"ymax"	=> $ymax,
			"zcen"	=> $center->[Z],
			"zmax"	=> $size->[Z],
			"xrot"	=> $instance->{rotationX},
			"yrot"	=> $instance->{rotationY},
			"zrot"	=> $instance->{rotation},
			"s"		=> $instance->{scaling_factor} * 100,
			"color"	=> \@array_color,
	);
	
	return %hash_data;
}

sub _go_slice {
	my $self = shift;
	my $commandline = shift;

	if ($self->{have_threads}) {
		local $SIG{'KILL'} = sub {
			threads->exit();
		};
	}
	
	_save_percentage($self, FILE_PERCENTAGE, 0);
	
	my $print;
	my %params;
	eval {
		$print = Slic3r::Print->new(config => $self->{config_slic3r});
		
		foreach my $object (@{$self->{model}->{objects}}) {
			$object->{instances}[0]->{scaling_factor} = 1;
			$object->{instances}[0]->{rotation} = 0;
		}
		
		$print->add_model($self->{model});
		
		$print->validate;
		
		%params = (
			output_file => $self->{config}->{http}{model} . OUTPUT_GCODE,
			status_cb   => sub {
				my ($percent, $message) = @_;
				printf "=> %s\n", $message;
				_save_percentage($self, FILE_PERCENTAGE, $percent, $message);
			},
		);
	};
	if ($@) {
		unlink($self->{config}->{http}{conf} . FILE_PERCENTAGE);
		_save_status($self, "Error", $commandline, "InitalError: " . $@);
		
		return;
	}
	
	eval {
		$print->export_gcode(%params);
	};
	if ($@) {
		unlink($self->{config}->{http}{conf} . FILE_PERCENTAGE);
		_save_status($self, "Error", $commandline, "ExportError: " . $@);
	} else {
		_save_status($self, "Done", $commandline);
	}
	
	$self->{thread} = undef;
	
	return;
}

sub _http_response {
	my $c = shift;
	my $options = shift;
	
	$c->send_response(
		HTTP::Response->new(
			RC_OK,
			undef,
			[
				'Content-Type' => $options->{content_type},
				'Cache-Control' => 'no-store, no-cache, must-revalidate, post-check=0, pre-check=0',
				'Pragma' => 'no-cache',
				'Expires' => 'Thu, 01 Dec 1994 16:00:00 GMT',
			],
			start_html(
				-title => 'Slic3r 1.00RC1 - HTTP daemon Zeepro mod',
				-encoding => 'utf-8',
				-style => { -code => $css },
			) .
			join("\n", @_) . 
			end_html(),
		)
	);
	
	return;
}

sub _http_response_text {
	my $c = shift;
	my $code = shift;
	
	$c->send_response(
		HTTP::Response->new(
			$code,
			undef,
			[
				'Content-Type' => 'text/plain',
				'Cache-Control' => 'no-store, no-cache, must-revalidate, post-check=0, pre-check=0',
				'Pragma' => 'no-cache',
				'Expires' => 'Thu, 01 Dec 1994 16:00:00 GMT',
			],
			join("\n", @_)
		)
	);
	
	return;
}

sub _save_status {
	my ($self, $state, $cmd, $msg) = @_;
	
	_save_JSON($self,
		FILE_STATUS,
		{
			"Version" => CURRENT_VERSION,
			"CommandLine" => $cmd,
			"Sate" => $state,
			"Cancel" => undef,
			"PauseOrResume" => undef,
			"CallBackURL" => undef,
			"Message" => $msg
		}
	);
	
	return;
}

sub _save_status_pHalt {
	my ($self, $state, $cmd, $halt, $msg) = @_;
	
	_save_JSON($self,
		FILE_STATUS,
		{
			"Version" => CURRENT_VERSION,
			"CommandLine" => $cmd,
			"Sate" => $state,
			"Cancel" => $halt,
			"PauseOrResume" => undef,
			"CallBackURL" => undef,
			"Message" => $msg
		}
	);
	
	return;
}

sub _save_percentage {
	my ($self, $file, $percent, $msg) = @_;
	
	_save_JSON($self,
		$file,
		{
			"percent" => $percent,
			"message" => $msg
		}
	);
	
	return;
}

sub _save_JSON {
	my ($self, $file, $json) = @_;

	open my $fh, ">", $self->{config}->{http}{conf} . $file;
	print $fh to_json($json);
	close $fh;
	
	return;
}

sub _load_JSON {
	my ($self, $file) = @_;

	my $json;
	
	local $/; #Enable 'slurp' mode
	open my $fh, "<", $self->{config}->{http}{conf} . $file;
	if (tell($fh) != -1) {
		$json = <$fh>;
		close $fh;
		
		return decode_json $json;
	} else {
		return undef;
	}
}

1;
