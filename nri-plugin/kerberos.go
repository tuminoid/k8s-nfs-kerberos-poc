/*
   Copyright The containerd Authors.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/containers/common/pkg/hooks"
	"github.com/sirupsen/logrus"
	"sigs.k8s.io/yaml"

	"github.com/containerd/nri/pkg/api"
	"github.com/containerd/nri/pkg/stub"
)

var (
	log *logrus.Logger
)

type plugin struct {
	stub stub.Stub
	mgr  *hooks.Manager
}

func (p *plugin) CreateContainer(_ context.Context, pod *api.PodSandbox, container *api.Container) (*api.ContainerAdjustment, []*api.ContainerUpdate, error) {
	var uid, gid, fsid uint64
	var username, realm, kdc, nfs string
	enabled := false
	renewal := false

	// dump the name
	ctrName := containerName(pod, container)
	fmt.Printf("%s: CreateContainer\n", ctrName)

	// check for annotations for uid/gid/fsid/enabled
	for k, v := range pod.Annotations {
		switch k {
		case "nri.io/kerberos-auth":
			if v == "enabled" {
				enabled = true
			}
			fmt.Printf("%s: %v\n", k, enabled)
		case "nri.io/kerberos-uid":
			uid, _ = strconv.ParseUint(v, 10, 32)
			fmt.Printf("%s: %d\n", k, uid)
		case "nri.io/kerberos-gid":
			gid, _ = strconv.ParseUint(v, 10, 32)
			fmt.Printf("%s: %d\n", k, gid)
		case "nri.io/kerberos-fsid":
			fsid, _ = strconv.ParseUint(v, 10, 32)
			fmt.Printf("%s: %d\n", k, fsid)
		default:
			// ignore
		}
	}

	// check the env vars for krb config
	for _, envVar := range container.Env {
		parts := strings.SplitN(envVar, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k, v := parts[0], parts[1]

		switch k {
		case "KERBEROS_USER":
			username = v
			fmt.Printf("%s: %s\n", k, username)
		case "KERBEROS_REALM":
			realm = v
			fmt.Printf("%s: %s\n", k, realm)
		case "KDC_HOSTNAME":
			kdc = v
			fmt.Printf("%s: %s\n", k, kdc)
		case "NFS_HOSTNAME":
			nfs = v
			fmt.Printf("%s: %s\n", k, nfs)
		case "KERBEROS_RENEWAL_TIME":
			renewal = true
			fmt.Printf("%s: %v\n", k, renewal)
		default:
			// ignore
		}
	}

	// bail out if all requirements are not met
	if !enabled || !renewal {
		fmt.Printf("%s: not enabled or not sidecar\n", ctrName)
		return nil, nil, nil
	}
	if uid == 0 || gid == 0 || fsid == 0 {
		fmt.Printf("%s: uid/gid/fsid annotation missing\n", ctrName)
		return nil, nil, nil
	}
	if username == "" || realm == "" || kdc == "" || nfs == "" {
		fmt.Printf("%s: username, realm, kdc, or nfs hostname missing\n", ctrName)
		return nil, nil, nil
	}

	// tbd - how do we pass the above to the script? exec the hook script?
	fmt.Printf("%s:WILL RUN KERBEROS SETUP SCRIPT HERE\n", ctrName)
	// hook script name from hook json?
	// #nosec G204:gosec
	cmd := exec.Command("/opt/nri-hooks/kerberos.sh", fmt.Sprintf("%d", uid), fmt.Sprintf("%d", gid), fmt.Sprintf("%d", fsid), username, realm, kdc, nfs)

	// nolint:errcheck
	cmd.CombinedOutput()

	//dump("Pod", pod)
	//dump("Container", container)

	return nil, nil, nil
}

// Construct a container name for log messages.
func containerName(pod *api.PodSandbox, container *api.Container) string {
	if pod != nil {
		return pod.Name + "/" + container.Name
	}
	return container.Name
}

// Dump one or more objects, with an optional global prefix and per-object tags.
func dump(args ...interface{}) {
	var (
		prefix string
		idx    int
	)

	if len(args)&0x1 == 1 {
		prefix = args[0].(string)
		idx++
	}

	for ; idx < len(args)-1; idx += 2 {
		tag, obj := args[idx], args[idx+1]
		msg, err := yaml.Marshal(obj)
		if err != nil {
			log.Infof("%s: %s: failed to dump object: %v", prefix, tag, err)
			continue
		}

		if prefix != "" {
			log.Infof("%s: %s:", prefix, tag)
			for _, line := range strings.Split(strings.TrimSpace(string(msg)), "\n") {
				log.Infof("%s:    %s", prefix, line)
			}
		} else {
			log.Infof("%s:", tag)
			for _, line := range strings.Split(strings.TrimSpace(string(msg)), "\n") {
				log.Infof("  %s", line)
			}
		}
	}
}

func main() {
	var (
		pluginIdx    string
		disableWatch bool
		opts         []stub.Option
		mgr          *hooks.Manager
		err          error
	)

	log = logrus.StandardLogger()
	log.SetFormatter(&logrus.TextFormatter{
		PadLevelText: true,
	})

	flag.StringVar(&pluginIdx, "idx", "", "plugin index to register to NRI")
	flag.BoolVar(&disableWatch, "disableWatch", false, "disable watching hook directories for new hooks")
	flag.Parse()

	if pluginIdx != "" {
		opts = append(opts, stub.WithPluginIdx(pluginIdx))
	}

	logrus.SetLevel(logrus.DebugLevel)

	p := &plugin{}
	if p.stub, err = stub.New(p, opts...); err != nil {
		log.Errorf("failed to create plugin stub: %v", err)
		os.Exit(1)
	}

	ctx := context.Background()
	dirs := []string{hooks.DefaultDir, hooks.OverrideDir}
	mgr, err = hooks.New(ctx, dirs, []string{})
	if err != nil {
		log.Errorf("failed to set up hook manager: %v", err)
		os.Exit(1)
	}
	p.mgr = mgr

	if !disableWatch {
		for _, dir := range dirs {
			if err = os.MkdirAll(dir, 0755); err != nil {
				log.Errorf("failed to create directory %q: %v", dir, err)
				os.Exit(1)
			}
		}

		sync := make(chan error, 2)
		go mgr.Monitor(ctx, sync)

		err = <-sync
		if err != nil {
			log.Errorf("failed to monitor hook directories: %v", err)
			os.Exit(1)
		}
		log.Infof("watching directories %q for new changes", strings.Join(dirs, " "))
	}

	err = p.stub.Run(ctx)
	if err != nil {
		log.Errorf("plugin exited with error %v", err)
		os.Exit(1)
	}
}
