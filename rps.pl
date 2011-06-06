#!perl

use strict;

use JSON;
use LWP::UserAgent;
use Image::Size;
use File::Path;



sub main()
{
  my $config = config() || return 1;
  
  my %done;
  dbmopen(%done, 'done.db', 0666) || return 2;
  
  foreach my $reddit (split(/[;,\s]+/, $config->{reddits}))
  {
    my $top = $config->{top} || 100;
    my $count = 0;
    my $after;
    while($count < $top)
    {
      my $data = geturl(url => "http://www.reddit.com/r/$reddit/.json".($after ? "?after=$after" : ''));
      if(!$data)
      {
        print(STDERR "get $reddit/$count error\n");
        return 2;
      }
      
      my $json = from_json($data);
      if(!$json->{data}{children} || !@{$json->{data}{children}}) { last; }
      
      $after = undef;
      foreach my $c (@{$json->{data}{children}})
      {
        if($c->{kind} ne 't3') { next; }
        $c = $c->{data};
        $after = 't3_'.$c->{id};
        
        $count++;
        
        print("asset $count: $c->{id}... ");
        print("url: $c->{url}... ");

        if($done{$c->{id}}) { print("previously done\n"); next; }
        if($c->{url} =~ /#/) { print("anchor magic\n"); next; }
        if(exists($config->{score}) && $c->{score} < $config->{score}) { print("score ($c->{score}) to low\n"); next; }
        if(exists($config->{num_comments}) && $c->{num_comments} < $config->{num_comments}) { print("num_comments ($c->{num_comments}) to low\n"); next; }
        if(exists($config->{ups}) && $c->{ups} < $config->{ups}) { print("ups ($c->{ups}) to low\n"); next; }
        
        my $img;
        my $full = 1;
        if($c->{url} =~ /\.(jpg|jpeg)$/) { $full = 0; }

        my $url = $c->{url};
        my $ref;
        
        ### skip imgur wrapper ###
        if($url =~ s|//imgur.com/|//i.imgur.com/|) { $url .= '.jpg'; }
        if($url =~ m|//i.primgur.com/| && $url !~ /\.jpg$/) { print("no jpeg...\n"); next; }
        
        ### switch flickr view ###
        #http://www.flickr.com/photos/user/###/in/set-###
        #http://www.flickr.com/photos/user/###/sizes/l/in/set-###
        if($url =~ m|//www.flicker.com/photos| && $url !~ m|/size/l/|)
        {
          $url =~ s|/in/|/size/o/in/|;
        }
        
        if($full)
        {
          $data = geturl(url => $url);
        }
        else
        {
          $data = geturl(url => $url, header => { Range => 'bytes=0-50000' });
        }
        
        if($data =~ /<html/i)
        {
          print("html wrapper... ");
          if(!$full)
          {
            $data = geturl(url => $c->{url});
            $full = 1;
          }
          
          if($url =~ m|//www.flickr.com/|)
          {
            $data =~ s|\s||g;
            if($data !~ m|<divid="allsizes-photo">.*?<imgsrc="(.*?)"></div>|) { print("un-flickr error\n"); $done{$c->{id}} = 3; next; }
            $ref = $url;
            $url = $1;
          }
          else
          {
            print("no html unwrapper\n");
            next;
          }

          $data = geturl(url => $url, header => { Referrer => $ref, Range => 'bytes=0-50000' });      
        }
        
        if($data =~ /^\xff\xd8/) ### jpeg header
        {
          $img = { data => $data, url => $c->{url} };
        }
        else
        {
          print("strange/no data\n");
          next;
        }

        $done{$c->{id}} = 1;
        
        my ($w, $h) = imgsize(\$img->{data});
        if(!$w || !$h)
        {
          print("no imgsize in preview... ");
          if(!$img->{full})
          {
            $img->{data} = geturl(url => $c->{url});
            ($w, $h) = imgsize(\$img->{data});
            if(!$w || !$h)
            {
              print("no imgsize in full\n");
              next;
            }
          }
        }

        my $r = $w / $h;
        my $p = $w * $h;

        if($config->{width}[0] && $w < $config->{width}[0]) { print("witdh ($w) to low\n"); next; }
        if($config->{width}[1] && $w > $config->{width}[1]) { print("witdh ($w) to high\n"); next; }
        if($config->{height}[0] && $h < $config->{height}[0]) { print("height ($h) to low\n"); next; }
        if($config->{height}[1] && $h > $config->{height}[1]) { print("height ($h) to high\n"); next; }
        if($config->{ratio}[0] && $r < $config->{ratio}[0]) { printf("ratio (%.3f) to low\n", $r); next; }
        if($config->{ratio}[1] && $r > $config->{ratio}[1]) { printf("ratio (%.3f) to high\n", $r); next; }
        if($config->{pixel}[0] && $p < $config->{pixel}[0]) { print("pixel ($p) to low\n"); next; }
        if($config->{pixel}[1] && $p > $config->{pixel}[1]) { print("pixel ($p) to high\n"); next; }

        my $t = $config->{target}.'/'.$c->{id}.'.jpg';
        
        if(!$img->{full})
        {
          $img->{data} = geturl(url => $img->{url});
        }
        if(!$data) { print("get error"); next; }
        my $fh;
        if(!open($fh, '>', $t)) { print("create error\n"); }
        binmode($fh);
        print($fh $img->{data});
        close($fh);          

        $done{$c->{id}} = 2;
        print("ok\n");
      }
      if(!$after) { last; }
    }    

    ### reddit API ask for max 2 request per second, let be nice ###
    sleep(1);  
  }
  
  dbmclose(%done);
  
  cleanup($config);
  
  return 0;
}





sub config()
{
  my $fh;
  if(!open($fh, '<', 'config'))
  {
    print(STDERR "cant open config\n");
    return;
  }
  
  my $r = {};
  while(my $l = <$fh>)
  {
    $l =~ s/^\s+|\s+$//g;
    next if($l =~ /^;/ || $l eq '');
    my ($k, $v) = split(/\s*=\s/, $l, 2);
    
    $r->{$k} = $v;
  }
  close($fh);
  
  foreach my $k (qw(width height ratio pixel))
  {
    next if(!exists($r->{$k}));
    $r->{$k} = [ split(/\s*\.\.\s*/, $r->{$k}) ];
  }
  
  if($r->{ratio}[0] && $r->{ratio}[0] =~ /(\d+):(\d+)/) { $r->{ratio}[0] = $1/$2; }
  if($r->{ratio}[1] && $r->{ratio}[1] =~ /(\d+):(\d+)/) { $r->{ratio}[1] = $1/$2; }
  
  $r->{target} ||= 'data';
  if(!-d $r->{target})
  {
    if(!mkpath($r->{target}))
    {
      print(STDERR "cant create target dir\n");
      return;
    }
  }
  
  return $r;  
}



sub geturl()
{
  my %_args = @_;

  #print("url: $_args{url}\n");
  
  my $ua = new LWP::UserAgent(agent => $_args{agent});
  my $req = new HTTP::Request(GET => $_args{url});
  if($_args{header})
  {
    $req->header(%{$_args{header}});
  }
  
  my $res = $ua->request($req);

  if(!$res->is_success())
  {
    return;
  }
    
  return $res->content();
}



sub cleanup($)
{
  my ($config) = @_;
  
  if(!$config->{maxdisk} && !$config->{maxage} && !$config->{maxfiles}) { return; }
  
  my $dh;
  opendir($dh, $config->{target});
  my @f;
  while(my $e = readdir($dh))
  {
    next if($e =~ /^\.+$/);
    my $f = $config->{target}.'/'.$e;
    push(@f, [ $f, (stat($f))[7, 9]]); ### size & modtime
  }
  closedir($dh);
  
  @f = sort { $b->[2] <=> $a->[2] } @f;
  
  if($config->{maxfiles})
  {
    while(@f > $config->{maxfiles})
    {
      my $f = shift(@f);
      print("cleanup: maxfiles $f->[0]\n");
      unlink($f->[0]);
    }
  }

  if($config->{maxdisk})
  {
    my $c = 0;
    foreach my $f (@f)
    {
      $c += $f->[1];
      if($c > $config->{maxdisk}*1024*1024)
      {
        print("cleanup: maxdisk $f->[0]\n");
        unlink($f->[0]);
      }
    }
  }

  if($config->{maxage})
  {
    foreach my $f (@f)
    {
      if(($f->[2]-time())/(24*60*60) > $config->{maxage})
      {
        print("cleanup: maxage $f->[0]\n");
        unlink($f->[0]);
      }
    }
  }
}



exit main();
