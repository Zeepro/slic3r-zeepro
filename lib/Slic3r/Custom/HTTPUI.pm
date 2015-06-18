package Slic3r::Custom::HTTPUI;

use strict;
use warnings;

use CGI qw/ :standard /;
#use Data::Dumper;
use HTTP::Daemon;
use HTTP::Response;
use HTTP::Status;
use URI;
use URI::QueryParam;

use threads;
#use threads::shared;
use utf8;
use JSON;
use File::Basename qw(basename);

use Slic3r::XS; # import all symbols (constants etc.) before they get parsed
use Slic3r::Model;
use Slic3r::Config;
use Slic3r::Geometry qw(X Y Z);
#use Slic3r::Print;

use constant CONFIG_HTTP	=> "config_http.ini";

use constant CONFIG_SLICER		=> "config.ini";
use constant OUTPUT_RENDERAMF	=> "_slicer_preview.amf";
use constant OUTPUT_RENDERSTL	=> "_slicer_preview.stl";
use constant OUTPUT_GCODE		=> "_sliced_model.gcode";
use constant OUTPUT_AMF			=> "_slicer_model.amf";
use constant OUTPUT_STL			=> "_slicer_model.stl";
#use constant OUTPUT_PREVIEW		=> "preview.png";
use constant OUTPUT_PREVIEW		=> "preview.tga";
use constant FILE_STATUS		=> "Slicer.json";
use constant FILE_PERCENTAGE	=> "Percentage.json";
use constant FILE_PORT			=> "Slic3rPort.txt";
#use constant FILE_IN_ADD		=> "add.tmp";
use constant D_NUMBER_EXTRUDER	=> 2;
use constant D_HEIGHT_PLATFORM	=> 150;

use constant CURRENT_VERSION	=> "1.0";
use constant START_PORT			=> 8080;
use constant LISTEN_IP			=> '0.0.0.0'; # 'localhost' for local use only, '0.0.0.0' for all access

my $number_extruder = D_NUMBER_EXTRUDER; # assign a default value
my $height_platform = D_HEIGHT_PLATFORM; # assign a default value
my $css = <<CSS;
		form { display: inline; }
CSS

our $Config;

sub new {
	my $class = shift;
	my $config = shift;
	my $self;
	my $port_try = START_PORT;
	
	# pass config to this class to avoid using the default settings - peng
	$self->{config_slic3r} = $config;
	
	$self->{have_threads} = $Slic3r::have_threads;
#	print "have_threads: $Slic3r::have_threads\n";
#	$Slic3r::have_threads = 0;
	
	$self->{model} = undef;
	$self->{thread} = undef;
	
	# Config file under the root
	$self->{config} = Slic3r::Config->read_ini(CONFIG_HTTP);
	unless (exists($self->{config}->{http}{systemconf}) && 
			exists($self->{config}->{http}{sdconf}) &&
			exists($self->{config}->{http}{conf}) &&
			exists($self->{config}->{http}{model}) &&
			exists($self->{config}->{http}{preview}) &&
			exists($self->{config}->{http}{hardconf})) {
		die "Incorrect or missing config file\n";
	}
	
	{
		my $jsonfile = $self->{config}->{http}{hardconf};
		if ( -e $jsonfile ) {
			my $printerinfo = _load_JSON_path($self, $self->{config}->{http}{hardconf});
			if (defined($printerinfo)) {
				if (defined($printerinfo->{xmax}) && defined($printerinfo->{ymax})) {
					$self->{config_slic3r}->set("bed_size", [$printerinfo->{xmax},$printerinfo->{ymax}]);
					$self->{config_slic3r}->set("print_center", [$printerinfo->{xmax} / 2,$printerinfo->{ymax} / 2]);
					print "Bed size found: X$printerinfo->{xmax}, Y$printerinfo->{ymax}\n";
				}
				if (defined($printerinfo->{ExtrudersNumber})) {
					$number_extruder = $printerinfo->{ExtrudersNumber};
					print "Extruder number found: $number_extruder\n";
				}
				if (defined($printerinfo->{zmax})) {
					$height_platform = $printerinfo->{zmax};
					print "Platform height found: $height_platform\n";
				}
			}
		}
	}
	
	while (1) {
		eval {
			$self->{d} = HTTP::Daemon->new(
					LocalAddr => LISTEN_IP,
					LocalPort => $port_try) || die "Port in use";
			
			1;
		};
		if ($@) {
			++$port_try;
		} else {
			print "Start on port $port_try...\n";
			
			open my $fh, ">", $self->{config}->{http}{conf} . FILE_PORT;
			print $fh $port_try;
			close $fh;
			last;
		}
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
					#TODO FIXME remove me as soon as possible
					# (halt will lead problem of slic3r, so we exit by myself)
					$c->close;
					undef($c);
					return;
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
#					Set model coordinate by ID
					
					set_model($self, $r, $c);
				} elsif ($r->uri->path eq "/resetmodel") {
#					Reset model coordinate by ID
					
					reset_model($self, $r, $c);
				} elsif ($r->uri->path eq "/preview") {
#					Rendering model preview (can't be interrupted)
					
					preview_model($self, $r, $c);
				} elsif ($r->uri->path eq "/slicestatus") {
#					Check slicing status
					
					check_slice($self, $r, $c);
				} elsif ($r->uri->path eq "/setparameter") {
#					Set temporary parameters
					
					set_parameter($self, $r, $c);
				} elsif ($r->uri->path eq "/getparameter") {
#					Get current parameters
					
					get_parameter($self, $r, $c);
				} elsif ($r->uri->path eq "/checksizes") {
#					Check all model sizes
					
					check_sizes($self, $r, $c);
				} elsif ($r->uri->path eq "/export2render") {
#					Export AMF of model(s)
					
					export_toRender($self, $r, $c);
				} elsif ($r->uri->path eq "/export2slice") {
#					Export STL or AMF of model(s) to slice at distance
					
					export_toSlice($self, $r, $c);
				} elsif ($r->uri->path eq "/test") {
#					Test method
					
					test_function($self, $r, $c);
				} else {
#					Splash screen...
					
					_http_response_text($c, 200, 'Slic3r 1.1.7b20150323 - HTTP daemon Zeepro mod');
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
	my $scale_max = undef;
	my $model_size;
	print "Request: add_file\n";
	if (defined($r->uri->query_param("noresize"))) {
		print "\t\tnoresize version\n";
	}
	
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
				{
					my $new_object = $self->{model}->add_object;
					my $model_name = undef;
					
					for my $m (0 .. $#models) {
						my $model = $models[$m];
						my $material_name = basename($array_file[$m]);
						
						$material_name =~ s/\.(stl|obj)$//i;
						if (defined($model_name)) {
							$model_name .= '|' . $array_file[$m];
						}
						else {
							$model_name = $array_file[$m];
						}
						
						# default attribute assignment not work, so we set its attribute again after creation
						$self->{model}->set_material("$m", { Name => $material_name });
						$self->{model}->get_material($m)->set_attribute("Name", $material_name);
						
						$new_object->add_volume(
							material_id	=> "$m",
							mesh		=> $model->objects->[0]->volumes->[0]->mesh,
						);
					}
					unless (defined($model_name)) {
						$model_name = $models[0]->objects->[0]->input_file;
					}
					$new_object->set_input_file($model_name);
				}
			}
			
#			print "volumes count: " . Dumper(scalar @{$self->{model}->objects->[0]->volumes});
#			print "materials_count: " . Dumper($self->{model}->objects->[0]->materials_count);
			$number_material = $self->{model}->objects->[0]->materials_count;
			if ($number_material > $number_extruder) {
				die("Model more than " . $number_extruder . " materials");
			}
			
			$self->{model}->add_default_instances();
			$self->{model}->objects->[0]->center_around_origin;
			$self->{model}->arrange_objects($self->{config_slic3r}->min_object_distance);
			
			{ # assign / init extruder
				my $model_object = $self->{model}->objects->[0];
				foreach my $i (0..$#{$model_object->volumes}) {
					my $volume = $model_object->volumes->[$i];
					if (defined $volume->material_id) {
						my $material = $model_object->model->get_material($volume->material_id);
						my $config = $material->config;
						my $extruder_id = $i % $number_extruder + 1; # assign only with available extruder
						$config->set_ifndef('extruder', $extruder_id);
					}
				}
			}
			
			{ # check model size
				my $bed_size = $self->{config_slic3r}->bed_size;
#				$model_size = $self->{model}->objects->[0]->bounding_box->size;
#				print "bed size x: " . Dumper($bed_size->[X]);
#				print "bed size y: " . Dumper($bed_size->[Y]);
				$model_size = $self->{model}->objects->[0]->raw_mesh->bounding_box->size;
				
				for my $scale_axis ($bed_size->[X] / $model_size->[X],
						$bed_size->[Y] / $model_size->[Y],
						$height_platform / $model_size->[Z]) {
					if (!defined($scale_max) || $scale_axis < $scale_max) {
						$scale_max = $scale_axis;
					}
				};
				
				# floor the scale value around pourcentage interger
				$scale_max = int($scale_max * 100) / 100;
				print "scale max: $scale_max\n";
				
				if ($scale_max < 1) {
					if (defined($r->uri->query_param("noresize"))) {
						$self->{model}->center_instances_around_point($self->{config_slic3r}->print_center);
						
						die("parts won't fit in your print area!");
					}
					else {
						$_->set_scaling_factor($scale_max) for @{ $self->{model}->objects->[0]->instances };
						$self->{model}->objects->[0]->center_around_origin;
					}
				}
			}
			
			$self->{model}->center_instances_around_point($self->{config_slic3r}->print_center);
			$self->_print_info(); #test
			
			1;
		};
		if ($@) {
			if (index($@, "parts won't fit in your print area!") != -1
					&& defined($r->uri->query_param("noresize"))) {
				_upload_model_info($self, $c, $model_size, $scale_max);
			}
			else {
				_http_response_text($c, 433, $@);
			}
		} else {
			if (defined($r->uri->query_param("noresize"))) {
				_upload_model_info($self, $c, $model_size, $scale_max);
			}
			else {
				_http_response_text($c, 200, 'Ok');
			}
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
	if (defined($self->{model})) {
		foreach my $object (@{$self->{model}->objects}) {
			$id_object++;
			my %hash_data = _model_info($self, $object);
			$hash_data{id} = $id_object;
			push(@array_json, \%hash_data);
		}
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
		if (defined($self->{model}->objects->[$model_id])) {
			$self->{model}->delete_object($model_id);
			if (scalar @{$self->{model}->objects}) {
				$self->{model}->arrange_objects($self->{config_slic3r}->min_object_distance);
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
			if (defined($self->{model}->objects->[$model_id])) {
				_http_response_text($c, 200, $self->{model}->objects->[$model_id]->input_file);
			} else {
				_http_response_text($c, 433, 'Incorrect parameter');
			}
		}
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub check_sizes {
	my ($self, $r, $c) = @_;
	print "Request: check_size\n";
	
	unless (defined($self->{model})) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		my $oversize = 0;
		my $code = 200;
		
		$oversize = _check_size_total($self);
		if ($oversize > 0) {
			$code = 202;
		}
		_http_response_text($c, $code, $oversize);
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
#		unless (defined($r->uri->query_param("id"))
#				&& defined($r->uri->query_param("xpos"))
#				&& defined($r->uri->query_param("ypos"))
#				&& defined($r->uri->query_param("zpos"))
#				&& defined($r->uri->query_param("xrot"))
#				&& defined($r->uri->query_param("yrot"))
#				&& defined($r->uri->query_param("zrot"))
#				&& defined($r->uri->query_param("s")) #scale
#				&& defined($r->uri->query_param("c")) #color
#				) {
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
			if (defined($self->{model}->objects->[$model_id])) {
				eval {
					my $object = $self->{model}->objects->[$model_id];
					if (defined($color)) {
						my $array_color = decode_json($color);
						my $nb_color = scalar @{$array_color};
						my $nb_volume = scalar @{$object->volumes};
						if ($nb_color != $nb_volume) {
							die("Incorrect color");
						}
						
#						print "color to set: " . Dumper($array_color);
						foreach my $i (0..$#{$object->volumes}) {
							my $volume = $object->volumes->[$i];
							if (defined $volume->material_id) {
								my $material = $object->model->get_material($volume->material_id);
								my $config = $material->config;
								$config->set('extruder', int $array_color->[$i]);
							}
						}
					}
					
					#TO/DO do some more intelligent action here for rotation
					my %hash_data = _model_info($self, $object);
					my $scale_ori = $hash_data{s} / 100;
					my $zrot_ori = $hash_data{zrot} * 1;
					my $xrot_ori = $hash_data{xrot} * 1;
					my $yrot_ori = $hash_data{yrot} * 1;
					my $need_rotation = 0;
					
					if (defined($scale)) {
						$scale /= 100; # percentage to real
						print "scale: " . $scale_ori . "=>" . $scale . "\n";
						$_->set_scaling_factor($scale) for @{ $object->instances };
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
						foreach my $instance (@{ $object->instances }) {
							if (defined($zrot)) {
								$instance->set_rotation($zrot);
							}
							if (defined($xrot)) {
								$instance->set_rotationX($xrot);
							}
							if (defined($yrot)) {
								$instance->set_rotationY($yrot);
							}
						}
					}
					$object->center_around_origin;
					$self->_print_info(); #test
					
					# return to original status if error
					my $bed_size = $self->{config_slic3r}->bed_size;
					%hash_data = _model_info($self, $object);
					if (_check_size_model($bed_size, \%hash_data)) {
						if (defined($scale)) {
							$_->set_scaling_factor($scale_ori) for @{ $object->instances };
						}
						if ($need_rotation > 0) {
							foreach my $instance (@{ $object->instances }) {
								$instance->set_rotation($zrot_ori);
								$instance->set_rotationX($xrot_ori);
								$instance->set_rotationY($yrot_ori);
							}
						}
						$object->center_around_origin;
						
						die("Incorrect setting to overload platform");
					}
					
					1;
				};
				if ($@) {
					print "ErrMsg: " . $@ . "\n";
					_http_response_text($c, 433, $@);
				} else {
#					_http_response_text($c, 200, 'Ok');
					my %hash_data = _model_info($self, $self->{model}->objects->[$model_id]);
					
					_http_response_text($c, 200, to_json(\%hash_data));
				}
				
				$self->_print_info(); #test
			} else {
				_http_response_text($c, 433, 'Incorrect parameter');
			}
		}
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub reset_model {
	my ($self, $r, $c) = @_;
	print "Request: reset_model\n";
	
	unless (defined($self->{model})) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		unless (defined($r->uri->query_param("id"))) {
			_http_response_text($c, 432, 'Missing parameter');
		}
		else {
			my $model_id = $r->uri->query_param("id");
			if (defined($self->{model}->objects->[$model_id])) {
				eval {
					my $object = $self->{model}->objects->[$model_id];
					
					$_->set_scaling_factor(1) for @{ $object->instances };
					foreach my $instance (@{ $object->instances }) {
						$instance->set_rotation(0);
						$instance->set_rotationX(0);
						$instance->set_rotationY(0);
					}
					$object->center_around_origin;
					
					# return to original status if error
					my $bed_size = $self->{config_slic3r}->bed_size;
					my %hash_data = _model_info($self, $object);
					if ($hash_data{smax} < 100) {
						my $scale_reset = int($hash_data{smax}) / 100;
						
						$self->_print_info(); #test
						$_->set_scaling_factor($scale_reset) for @{ $object->instances };
						$object->center_around_origin;
						
						%hash_data = _model_info($self, $object);
						
						if (_check_size_model($bed_size, \%hash_data)) {
							die("Reset parameters overloads platform with internal error");
						}
						
						$object->center_around_origin;
					}
					
					1;
				};
				
				if ($@) {
					print "ErrMsg: " . $@ . "\n";
					_http_response_text($c, 433, $@);
				} else {
					my %hash_data = _model_info($self, $self->{model}->objects->[$model_id]);
					
					_http_response_text($c, 200, to_json(\%hash_data));
				}
				
				$self->_print_info(); #test
			} else {
				_http_response_text($c, 433, 'Incorrect parameter');
			}
			
		}
	}
}

sub get_parameter {
	my ($self, $r, $c) = @_;
	print "Request: get_parameter\n";
	
	unless (defined($r->uri->query_param("p"))) {
		_http_response_text($c, 432, 'Missing parameter');
	}
	else {
		my $param_key = $r->uri->query_param("p");
		my $param_value = $self->{config_slic3r}->serialize($param_key) // undef; # get($param_key)
		
#		if (ref($param_value) eq "ARRAY") {
#			$param_value = $self->{config_slic3r}->serialize($param_key) // undef;
#		}
		if (defined($param_value)) {
			print $param_key . " = " . $param_value . "\n";
			_http_response_text($c, 200, $param_value);
		}
		else {
			_http_response_text($c, 433, 'Incorrect parameter');
		}
	}
	
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
	 || defined($r->uri->query_param("support_material"))
	 || defined($r->uri->query_param("bed_temperature"))) {
		_http_response_text($c, 432, 'Missing parameter');
	}
	else {
		if (defined($r->uri->query_param("fill_density"))) {
			$self->{config_slic3r}->set("fill_density", $r->uri->query_param("fill_density"));
			print "set fill_density " . $self->{config_slic3r}->get("fill_density") . "\n";
		}
		if (defined($r->uri->query_param("skirts"))) {
			$self->{config_slic3r}->set("skirts", $r->uri->query_param("skirts"));
			print "set skirts " . $self->{config_slic3r}->get("skirts") . "\n";
		}
		if (defined($r->uri->query_param("raft_layers"))) {
			$self->{config_slic3r}->set("raft_layers", $r->uri->query_param("raft_layers"));
			print "set raft_layers " . $self->{config_slic3r}->get("raft_layers") . "\n";
		}
		if (defined($r->uri->query_param("support_material"))) {
			$self->{config_slic3r}->set("support_material", $r->uri->query_param("support_material"));
			print "set support_material " . $self->{config_slic3r}->get("support_material") . "\n";
		}
		if (defined($r->uri->query_param("temperature"))) {
			$self->{config_slic3r}->set_deserialize("temperature", $r->uri->query_param("temperature"));
			print "set temperature " . $self->{config_slic3r}->serialize("temperature") . "\n";
		}
		if (defined($r->uri->query_param("first_layer_temperature"))) {
			$self->{config_slic3r}->set_deserialize("first_layer_temperature", $r->uri->query_param("first_layer_temperature"));
			print "set first_layer_temperature " . $self->{config_slic3r}->serialize("first_layer_temperature") . "\n";
		}
		if (defined($r->uri->query_param("bed_temperature"))) {
			my $set_value = $r->uri->query_param("bed_temperature");
			$self->{config_slic3r}->set("bed_temperature", $set_value);
			$self->{config_slic3r}->set("first_layer_bed_temperature", $set_value);
			print "set bed_temperature + first_layer_bed_temperature " . $self->{config_slic3r}->get("bed_temperature") . "\n";
		}
		
		_http_response_text($c, 200, 'Ok');
	}
	
	return;
}

sub preview_model {
	my ($self, $r, $c) = @_;
	my $object_preview;
	print "Request: preview_model\n";
	
	# only rendering the first object of model
	unless (defined($r->uri->query_param("rho"))
	 && defined($r->uri->query_param("theta"))
	 && defined($r->uri->query_param("delta"))) {
		_http_response_text($c, 432, 'Missing parameter');
		
		return;
	}
	
	unless (defined($self->{model})) {
		_http_response_text($c, 441, 'No model in system');
		
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
		my $object = $self->{model}->objects->[0];
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
		
		# delete old preview image
		unlink($image_file);
		
		$object_preview = Slic3r::Custom::Preview->new(
			$object, $input_rho, $input_theta, $input_delta, $image_file,
			$height_platform, $self->{config_slic3r}->bed_size,
			$data_color1, $data_color2);
		
		1;
	};
	if ($@) {
		_http_response_text($c, 433, $@);
	}
	else {
		eval {
			$object_preview->InitBuffer();
			$object_preview->Resize();
			$object_preview->Render();
#			$object_preview->ReleaseRessource();
			
			1;
		};
		if ($@) {
			eval {$object_preview->ReleaseRessource(); 1;};
			_http_response_text($c, 433, $@);
		} else {
			$object_preview->ReleaseRessource();
			_http_response_text($c, 200, 'Ok' . "\n" . $self->{config}->{http}{preview} . OUTPUT_PREVIEW);
			# for use: "<img src=\"" . $self->{config}->{http}{preview} . OUTPUT_PREVIEW . "\">"
		}
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
		_http_response_text($c, 500, 'can not find config file');
	}
	
	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub slice {
	my ($self, $r, $c) = @_;
	print "Request: slice\n";
	
	_save_status_pHalt($self, "Working", $r->uri->as_string, "/slicehalt");
	
	unless (defined($self->{model}) && scalar @{$self->{model}->objects} > 0) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
#		if ($Slic3r::have_threads) {
		if ($self->{have_threads}) { #TODO better check if we are in slicing or not
			$self->{thread} = threads->create(\&_go_slice, $self, $r->uri->as_string);
		} else {
			_go_slice($self, $r->uri->as_string);
		}
		_http_response_text($c, 200, 'Ok');
	}
	
#	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

#TODO FIXME this function will let the second call after halting failed and that will exit the slicer
sub slice_halt {
	my ($self, $r, $c) = @_;
	print "Request: slice_halt\n";
	
#	if ($Slic3r::have_threads) {
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
			chmod 0777, $self->{config}->{http}{model} . OUTPUT_GCODE;
			unlink($self->{config}->{http}{conf} . FILE_PERCENTAGE);
		} else {
			_http_response_text($c, 200, $data->{percent} . "\n" . $data->{message});
		}
	}
	
#	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub export_toRender {
	my ($self, $r, $c) = @_;
	print "Request: export_amf\n";
	
#	my $data = _load_JSON($self, FILE_STATUS);
	unless (defined($self->{model}) && scalar @{$self->{model}->objects} > 0) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		my $model_path;
		
		eval {
			my $number_material;
			
			$number_material = $self->{model}->objects->[0]->materials_count;
			
			if ($number_material == 1) {
				require Slic3r::Format::STL;
				
				$model_path = $self->{config}->{http}{model} . OUTPUT_RENDERSTL;
				Slic3r::Format::STL->write_file($model_path, $self->{model}->objects->[0]->raw_mesh, binary => 1);
			}
			else {
				require Slic3r::Custom::AMF;
				
				my $input_color1 = $r->uri->query_param("color1") // undef;
				my $input_color2 = $r->uri->query_param("color2") // undef;
				my %extra_data = ();
				my %model_data = _model_info($self, $self->{model}->objects->[0]);
				
				$extra_data{0}{color} = $input_color1;
				$extra_data{1}{color} = $input_color2;
				$model_path = $self->{config}->{http}{model} . OUTPUT_RENDERAMF;
				
				Slic3r::Custom::AMF->write_file($model_path, $self->{model}, $model_data{s}, \%extra_data);
			}
			chmod 0777, $model_path;
			
			1;
		};
		if ($@) {
			_http_response_text($c, 500, $@);
		} else {
			_http_response_text($c, 200, 'Ok' . "\n" . $model_path);
		}
	}
	
#	_save_status($self, "Done", $r->uri->as_string);
	
	return;
}

sub export_toSlice {
	my ($self, $r, $c) = @_;
	print "Request: export_toSlice\n";
	
	unless (defined($self->{model}) && scalar @{$self->{model}->objects} > 0) {
		_http_response_text($c, 441, 'Platform empty');
	} else {
		my $number_material;
		my $model_path;
		my $config_path = $self->{config}->{http}{model} . CONFIG_SLICER;
		
		eval {
			# clean old files
			unlink($config_path);
			unlink($self->{config}->{http}{model} . OUTPUT_STL);
			unlink($self->{config}->{http}{model} . OUTPUT_AMF);
			
			# export config
			$self->{config_slic3r}->save($config_path);
			
			# export model
			$number_material = $self->{model}->objects->[0]->materials_count;
			if ($number_material == 1) {
				require Slic3r::Format::STL;
				
				$model_path = $self->{config}->{http}{model} . OUTPUT_STL;
				Slic3r::Format::STL->write_file($model_path, $self->{model}, binary => 1);
			}
			else {
				require Slic3r::Format::AMF;
				
				$model_path = $self->{config}->{http}{model} . OUTPUT_AMF;
				Slic3r::Format::AMF->write_file($model_path, $self->{model});
			}
			chmod 0777, $model_path;
			
			1;
		};
		if ($@) {
			_http_response_text($c, 500, $@);
		} else {
			_http_response_text($c, 200, 'Ok' . "\n" . $config_path . "\n" . $model_path);
		}
	}
	
	return;
}

sub test_function {
	my ($self, $r, $c) = @_;
	print "Request: test_function\n";
	
#	my $data = _load_JSON($self, FILE_STATUS);
	_http_response_text($c, 200, 'Ok');
	
	return;
}

sub _init_file {
	#TODO check conf file version
}

sub _print_info() {
	my $self = shift;
	
	$self->{model}->print_info;
	
#	my $id_object = -1;
#	foreach my $object (@{$self->{model}->objects}) {
#		$id_object++;
#		my %hash_data = _model_info($self, $object);
#		$hash_data{id} = $id_object;
#		print "model info $id_object: " . Dumper(\%hash_data);
#	}
}

sub _model_info {
	my ($self, $object) = @_;
	
	my $bb = $object->bounding_box;
	my $center = $bb->center;
	my $size = $bb->size;
	my $instance = $object->instances->[0];
	my ($xpos, $ypos, $xcen, $ycen, $xmax, $ymax);
	my @array_color;
	my %hash_data;
	my $scale_max;
	
	{ # get color
		foreach my $i (0..$#{$object->volumes}) {
			my $volume = $object->volumes->[$i];
			if (defined $volume->material_id) {
				my $material = $object->model->get_material($volume->material_id);
				my $config = $material->config;
				push (@array_color, $config->extruder);
			}
		}
	}
	{ # get max scale (calculated by platform and model size, but not real situation)
		my $bed_size = $self->{config_slic3r}->bed_size;
		
		for my $scale_axis ($bed_size->[X] / $size->[X],
				$bed_size->[Y] / $size->[Y],
				$height_platform / $size->[Z]) {
			if (!defined($scale_max) || $scale_axis < $scale_max) {
				$scale_max = $scale_axis;
			}
		};
		
		$scale_max *= $instance->scaling_factor;
	}
	
#	$xcen = $self->{config_slic3r}->print_center->[X] + $instance->offset->[X];
#	$ycen = $self->{config_slic3r}->print_center->[Y] + $instance->offset->[Y];
	$xcen = $instance->offset->[X];
	$ycen = $instance->offset->[Y];
	$xpos = $xcen - $size->[X] / 2;
	$ypos = $ycen - $size->[Y] / 2;
	$xmax = $xcen + $size->[X] / 2;
	$ymax = $ycen + $size->[Y] / 2;
	%hash_data = (
			"xpos"	=> $xpos,
			"ypos"	=> $ypos,
			"zpos"	=> 0, #TODO deal it with model
			"xcen"	=> $xcen, # $center->[X],
			"ycen"	=> $ycen, # $center->[Y],
			"zcen"	=> $center->[Z],
			"xmax"	=> $xmax,
			"ymax"	=> $ymax,
			"zmax"	=> $size->[Z],
			"xsize"	=> $size->[X],
			"ysize"	=> $size->[Y],
			"zsize"	=> $size->[Z],
			"xrot"	=> $instance->rotationX,
			"yrot"	=> $instance->rotationY,
			"zrot"	=> $instance->rotation,
			"s"		=> $instance->scaling_factor * 100,
			"color"	=> \@array_color,
			"smax"	=> $scale_max * 100,
	);
	
	return %hash_data;
}

sub _check_size_model {
	my ($bed_size, $hash_data) = @_;
	
	if ($hash_data->{xpos} < 0 || $hash_data->{xmax} > $bed_size->[X]
			|| $hash_data->{ypos} < 0 || $hash_data->{ymax} > $bed_size->[Y]
			|| $hash_data->{zpos} < 0 || $hash_data->{zmax} > $height_platform
	) {
		return 1;
	}
	
	return 0;
}

sub _check_size_total {
#	my ($self, $object) = @_;
	my $self = shift;
	my %hash_data;
	my $oversize = 0;
	my $bed_size = $self->{config_slic3r}->bed_size;
	
	foreach my $object (@{$self->{model}->objects}) {
		%hash_data = _model_info($self, $object);
		
		$oversize += _check_size_model($bed_size, \%hash_data);
	}
	
	return $oversize;
}

sub _upload_model_info {
	my ($self, $c, $model_size, $scale_max) = @_;
	my %hash_return = (
		"id"	=> 0,
		"xsize"	=> $model_size->[X],
		"ysize"	=> $model_size->[Y],
		"zsize"	=> $model_size->[Z],
		"smax"	=> $scale_max * 100,
	);
	
	$self->_print_info(); #test
	
	_http_response_text($c, 202, to_json(\%hash_return));
	
	return;
}

sub _go_slice {
	my $self = shift;
	my $commandline = shift;
	
	if ($self->{have_threads}) {
		local $SIG{'KILL'} = sub {
			threads->exit();
		};
	}
	
	_save_percentage($self, FILE_PERCENTAGE, 1, "Initialization slicing");
	
	my $print;
	eval {
		$print = Slic3r::Print->new;
		$self->{config_slic3r}->validate;
		$print->apply_config($self->{config_slic3r});
		
		foreach my $model_object (@{$self->{model}->objects}) {
			#repair todo
			$model_object->mesh->repair;
			$print->add_model_object($model_object);
		}
		
		$print->validate;
	};
	if ($@) {
		unlink($self->{config}->{http}{conf} . FILE_PERCENTAGE);
		_save_status($self, "Error", $commandline, "InitalError: " . $@);
		
		return;
	}
	
	eval {
		$print->status_cb(sub {
				my ($percent, $message) = @_;
				printf "=> %s\n", $message;
				_save_percentage($self, FILE_PERCENTAGE, $percent, $message);
		});
		$print->process;
		$print->export_gcode(output_file => $self->{config}->{http}{model} . OUTPUT_GCODE);
		chmod 0777, $self->{config}->{http}{model} . OUTPUT_GCODE;
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

sub _load_JSON_path {
	my ($self, $file) = @_;

	my $json;
	
	local $/; #Enable 'slurp' mode
	open my $fh, "<", $file;
	if (tell($fh) != -1) {
		$json = <$fh>;
		close $fh;
		
		return decode_json $json;
	} else {
		return undef;
	}
}

#TEST - asynchronize adding file
#sub add_file {
#	my ($self, $r, $c) = @_;
#	
#	if (!$r->uri->query_param("file")) {
#		_http_response_text($c, 432, 'Missing parameter');
#	} else {
#		#	if ($Slic3r::have_threads) 
#		if ($self->{have_threads}) { #TO/DO better check if we are in slicing or not
#			$self->{thread} = threads->create(\&_go_add, $self, $r->uri->query_param("file"), $r->uri->as_string);
#		} else {
#			_go_add($self, $r->uri->query_param("file"), $r->uri->as_string);
#		}
#		
#		_http_response_text($c, 200, 'Ok');
#	}
#	
#	return;
#}

#sub check_add {
#	my ($self, $r, $c) = @_;
#	
#	unless( -e ($self->{config}->{http}{conf} . FILE_IN_ADD) ) {
#		my $data = _load_JSON($self, FILE_STATUS);
#		if (!defined($data)) {
#			_http_response_text($c, 500, "cannot open status file");
#		} elsif ($data->{Sate} eq "Error") {
#			_http_response_text($c, 499, $data->{Message});
#		} else {
#			_http_response_text($c, 200, -1);
#		}
#	} else {
#		my $data = _load_JSON($self, FILE_IN_ADD);
#		if (!defined($data)) {
#			_http_response_text($c, 500, "cannot open add file");
#		} elsif ($data->{percent} == 100) {
#			_http_response_text($c, 200, $data->{percent} . "\n" . $data->{message});
#			unlink($self->{config}->{http}{conf} . FILE_IN_ADD);
#			$self->{model} = $self->{thread}->join();
#			$self->{thread} = undef;
#		} else {
#			_http_response_text($c, 200, $data->{percent});
#		}
#	}
#	
#	
##	_save_status($self, "Done", $r->uri->as_string);
#	
#	return;
#}

#sub _go_add {
#	my ($self, $input_file, $commandline) = @_;
#
#	if ($self->{have_threads}) {
#		local $SIG{'KILL'} = sub {
#			threads->exit();
#		};
#	}
#	
#	_save_percentage($self, FILE_IN_ADD, 0);
#	
#	eval {
#		$self->{model} = Slic3r::Model->read_from_file($input_file);
#		_save_percentage($self, FILE_IN_ADD, 80, "Finished read file");
#		
#		$_->scale($self->{config_slic3r}->scale) for @{$self->{model}->objects};
#		_save_percentage($self, FILE_IN_ADD, 83, "Finished system scale");
#		$self->{model}->set_material(0, {Name => basename($self->{model}->{objects}[0]->{input_file})});
#		$self->{model}->{objects}->[0]->{volumes}->[0]->{material_id} = 0;
#		$self->{model}->{objects}->[0]->{material_mapping} = {0 => 1};
#		_save_percentage($self, FILE_IN_ADD, 85, "Finished setting material");
#		$self->{model}->arrange_objects($self->{config_slic3r});
#		_save_percentage($self, FILE_IN_ADD, 95, "Finished arrange");
#		
#		_print_info(); #test
#	};
#	if ($@) {
#		unlink($self->{config}->{http}{conf} . FILE_IN_ADD);
#		_save_status($self, "Error", $commandline, "AddError: " . $@);
#	} else {
#		_save_percentage($self, FILE_IN_ADD, 100, "AddDone");
#		_save_status($self, "Done", $commandline);
#	}
#	
#	$self->{thread} = undef;
#	
#	return $self->{model};
#}
#TEST end

1;
