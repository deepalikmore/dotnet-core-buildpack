# Encoding: utf-8
# ASP.NET Core Buildpack
# Copyright 2016 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

$LOAD_PATH << 'cf_spec'
require 'spec_helper'
require 'rspec'

describe AspNetCoreBuildpack::DotnetSdkInstaller do
  let(:dir) { Dir.mktmpdir }
  let(:cache_dir) { Dir.mktmpdir }
  let(:shell) { double(:shell, env: {}) }
  let(:out) { double(:out) }
  let(:self_contained_app_dir) { double(:self_contained_app_dir, published_project: 'project1') }
  let(:project_paths) { %w(project1 project2) }
  let(:app_dir) { double(:app_dir, published_project: false,
                         project_paths: project_paths) }
  let(:manifest_dir)  { Dir.mktmpdir }
  let(:manifest_file) { File.join(manifest_dir, 'manifest.yml') }
  let(:manifest_contents) do
    <<-YAML
doesn't matter for these tests
    YAML
  end

  before do
    allow(AspNetCoreBuildpack::DotnetSdkVersion).to receive(:new).with(any_args).and_return(double(version: '4.4.4-002222'))

    File.write(manifest_file, manifest_contents)
  end

  after do
    FileUtils.rm_rf(manifest_dir)
    FileUtils.rm_rf(dir)
  end

  subject(:installer) { described_class.new(dir, cache_dir, manifest_file, shell) }

  describe '#version' do
    it 'is always defined' do
      expect(installer.send(:version)).to_not eq(nil)
    end
  end

  describe '#cached?' do
    context 'cache directory exists in the buildpack cache' do
      before do
        FileUtils.mkdir_p(File.join(cache_dir, '.dotnet'))
      end

      context 'cached version is the same as the current version being installed' do
        before do
          File.open(File.join(cache_dir, '.dotnet', 'VERSION'), 'w') do |f|
            f.write '1.0.0-preview2-003121'
          end
        end

        it 'returns true' do
          allow(subject).to receive(:version).and_return('1.0.0-preview2-003121')
          expect(subject.send(:cached?)).to be_truthy
        end
      end

      context 'cached version is different than the current version being installed' do
        before do
          File.open(File.join(cache_dir, '.dotnet', 'VERSION'), 'w') do |f|
            f.write '1.0.0-preview2-003131'
          end
        end

        it 'returns false' do
          expect(subject.send(:cached?)).not_to be_truthy
        end
      end
    end

    context 'cache directory does not exist in the build directory' do
      it 'returns false' do
        expect(subject.send(:cached?)).not_to be_truthy
      end
    end
  end

  describe '#install' do
    it 'downloads file with compile-extensions and writes a version file' do
      allow(shell).to receive(:exec).and_return(0)
      expect(shell).to receive(:exec) do |*args|
        cmd = args.first
        expect(cmd).to match(/download_dependency/)
        expect(cmd).to match(/4.4.4-002222/)
        expect(cmd).to match(/tar/)
      end
      expect(out).to receive(:print).with(/.NET SDK version: /)
      expect(subject).to receive(:write_version_file).with(anything)
      subject.install(out)
    end
  end

  describe '#restore' do
    context 'intalled sdk uses msbuild' do
      let(:project_paths) { %w(src1/project1.csproj src2/project2.csproj) }

      before do
        allow(subject).to receive(:msbuild?).with(dir).and_return(true)
      end

      it 'runs dotnet restore and rewrites project.assets.json' do
        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet restore src1\/project1.csproj/)
        end
        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet restore src2\/project2.csproj/)
        end
        expect(subject).to receive(:rewrite_project_assets_json).with(%w(src1/project1.csproj src2/project2.csproj))

        subject.should_restore(app_dir)
        subject.restore(out)
      end
    end

    context 'installed sdk uses project.json ' do
      before do
        allow(subject).to receive(:msbuild?).with(dir).and_return(false)
      end

      it 'runs dotnet restore and does not rewrite project.assets.json' do
        expect(shell).to receive(:exec) do |*args|
          cmd = args.first
          expect(cmd).to match(/dotnet restore project1 project2/)
        end
        expect(subject).not_to receive(:rewrite_project_assets_json)

        subject.should_restore(app_dir)
        subject.restore(out)
      end
    end
  end

  describe '#rewrite_project_assets_json' do
    let(:csproj_files) { %w(src1/project1.csproj src2/project2.csproj) }

    before do
      FileUtils.mkdir_p(File.join(dir, 'src1', 'obj'))
      FileUtils.mkdir_p(File.join(dir, 'src2', 'obj'))

      File.write(File.join(dir, 'src1', 'obj', 'project.assets.json'), '/tmp/app/.nuget/packages/')
      File.write(File.join(dir, 'src2', 'obj', 'project.assets.json'), '/tmp/app/.nuget/packages/')
    end

    it 'substitutes runtime nuget package dir for staging dir in all projects' do
      subject.rewrite_project_assets_json(csproj_files)

      expect(File.read(File.join(dir, 'src1', 'obj', 'project.assets.json'))).to eq '/app/.nuget/packages/'
      expect(File.read(File.join(dir, 'src2', 'obj', 'project.assets.json'))).to eq '/app/.nuget/packages/'
    end
  end

  describe '#should_install' do
    context 'app is self-contained' do
      before do
        File.open(File.join(dir, 'project1'), 'w') { |f| f.write('a') }
      end

      it 'returns false' do
        expect(subject.should_install(self_contained_app_dir)).not_to be_truthy
      end
    end

    context 'app is not self-contained' do
      it 'returns true' do
        expect(subject.should_install(app_dir)).to be_truthy
      end
    end
  end

  describe '#should_restore' do
    context 'app is portable or self-contained' do
      it 'returns false' do
        expect(subject.should_restore(self_contained_app_dir)).not_to be_truthy
      end
    end

    context 'app is not portable or self-contained' do
      it 'returns true' do
        expect(subject.should_restore(app_dir)).to be_truthy
      end
    end
  end

  describe '#write_version_file' do
    before do
      FileUtils.mkdir_p(File.join(dir, '.dotnet'))
    end

    it 'writes a version file with the current .NET version' do
      subject.send(:write_version_file, '1.0.0')
      expect(File.exist?(File.join(dir, '.dotnet', 'VERSION'))).to be_truthy
    end
  end
end
