package Slic3r::Custom::AMF;
use Moo;

use Slic3r::Geometry qw(X Y Z);
use JSON;
use Slic3r::Custom::Preview qw(COLORS);

sub _convert_amf_color {
	# convert opengl constant array in preview to normal rgb hex
	my $color_array = shift;
	
	return sprintf("#%X%X%X", int($color_array->[2] * 255), int($color_array->[1] * 255), int($color_array->[0] * 255));
}

sub write_file {
    my $self = shift;
    my ($file, $model, $size, $extra_data, %params) = @_; #DIY add size and extra data hash ref in parameter - PNI
    
    my %vertices_offset = ();
	my $nb_material = scalar @{ $model->material_names };
    
    Slic3r::open(\my $fh, '>', $file);
    binmode $fh, ':utf8';
    printf $fh qq{<?xml version="1.0" encoding="UTF-8"?>\n};
    printf $fh qq{<amf unit="millimeter">\n};
    printf $fh qq{  <metadata type="cad">Slic3r %s</metadata>\n}, $Slic3r::VERSION;
	printf $fh qq{  <metadata type="scale">%.2f</metadata>\n}, $size; #DIY add size in metadata - PNI
    for my $material_id (sort @{ $model->material_names }) {
        my $material = $model->get_material($material_id);
        printf $fh qq{  <material id="%s">\n}, $material_id;
        for (keys %{$material->attributes}) {
             printf $fh qq{    <metadata type=\"%s\">%s</metadata>\n}, $_, $material->attributes->{$_};
        }
        my $config = $material->config;
        foreach my $opt_key (@{$config->get_keys}) {
             printf $fh qq{    <metadata type=\"slic3r.%s\">%s</metadata>\n}, $opt_key, $config->serialize($opt_key);
        }
		
		#DIY find correspondent hash data, print all of them, then print default color if it's not in passing data
		my $extra_id = ($nb_material == 1) ? 0 : $material_id;
		if (defined($extra_data->{$extra_id})) {
			for (keys $extra_data->{$extra_id}) {
				if (defined($extra_data->{$extra_id}->{$_})) {
#					my $output_value = $extra_data->{$extra_id}->{$_};
#					if ($_ eq 'color') {
#						$output_value = _convert_amf_color($output_value);
#					}
#					printf $fh qq{    <metadata type=\"%s\">%s</metadata>\n}, $_, $output_value;
					printf $fh qq{    <metadata type=\"%s\">%s</metadata>\n}, $_, $extra_data->{$extra_id}->{$_};
				}
			}
		}
		unless (defined($extra_data->{$extra_id}->{color})) {
			printf $fh qq{    <metadata type=\"color\">%s</metadata>\n}, _convert_amf_color(Slic3r::Custom::Preview::COLORS->[$extra_id]);
		}
		#DIY end - PNI
		
        printf $fh qq{  </material>\n};
    }
    my $instances = '';
    for my $object_id (0 .. $#{ $model->objects }) {
        my $object = $model->objects->[$object_id];
        printf $fh qq{  <object id="%d">\n}, $object_id;
        
        my $config = $object->config;
        foreach my $opt_key (@{$config->get_keys}) {
             printf $fh qq{    <metadata type=\"slic3r.%s\">%s</metadata>\n}, $opt_key, $config->serialize($opt_key);
        }
        
        printf $fh qq{    <mesh>\n};
        printf $fh qq{      <vertices>\n};
        my @vertices_offset = ();
        {
            my $vertices_offset = 0;
            foreach my $volume (@{ $object->volumes }) {
                push @vertices_offset, $vertices_offset;
                my $vertices = $volume->mesh->vertices;
                foreach my $vertex (@$vertices) {
                    printf $fh qq{        <vertex>\n};
                    printf $fh qq{          <coordinates>\n};
                    printf $fh qq{            <x>%s</x>\n}, $vertex->[X];
                    printf $fh qq{            <y>%s</y>\n}, $vertex->[Y];
                    printf $fh qq{            <z>%s</z>\n}, $vertex->[Z];
                    printf $fh qq{          </coordinates>\n};
                    printf $fh qq{        </vertex>\n};
                }
                $vertices_offset += scalar(@$vertices);
            }
        }
        printf $fh qq{      </vertices>\n};
        foreach my $volume (@{ $object->volumes }) {
            my $vertices_offset = shift @vertices_offset;
            printf $fh qq{      <volume%s>\n},
                (!defined $volume->material_id) ? '' : (sprintf ' materialid="%s"', $volume->material_id);
            
            my $config = $volume->config;
            foreach my $opt_key (@{$config->get_keys}) {
                 printf $fh qq{        <metadata type=\"slic3r.%s\">%s</metadata>\n}, $opt_key, $config->serialize($opt_key);
            }
            if ($volume->modifier) {
                printf $fh qq{        <metadata type=\"slic3r.modifier\">1</metadata>\n};
            }
        
            foreach my $facet (@{$volume->mesh->facets}) {
                printf $fh qq{        <triangle>\n};
                printf $fh qq{          <v%d>%d</v%d>\n}, $_, $facet->[$_-1] + $vertices_offset, $_ for 1..3;
                printf $fh qq{        </triangle>\n};
            }
            printf $fh qq{      </volume>\n};
        }
        printf $fh qq{    </mesh>\n};
        printf $fh qq{  </object>\n};
        if ($object->instances) {
            foreach my $instance (@{$object->instances}) {
                $instances .= sprintf qq{    <instance objectid="%d">\n}, $object_id;
                $instances .= sprintf qq{      <deltax>%s</deltax>\n}, $instance->offset->[X];
                $instances .= sprintf qq{      <deltay>%s</deltay>\n}, $instance->offset->[Y];
                $instances .= sprintf qq{      <rz>%s</rz>\n}, $instance->rotation;
                $instances .= sprintf qq{    </instance>\n};
            }
        }
    }
    if ($instances) {
        printf $fh qq{  <constellation id="1">\n};
        printf $fh $instances;
        printf $fh qq{  </constellation>\n};
    }
    printf $fh qq{</amf>\n};
    close $fh;
}

1;
