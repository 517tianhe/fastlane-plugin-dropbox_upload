describe Fastlane::Actions::DropboxUploadAction do
  describe '#run' do
    it 'prints a message' do
      expect(Fastlane::UI).to receive(:message).with("The dropbox_upload plugin is working!")

      Fastlane::Actions::DropboxUploadAction.run(nil)
    end
  end
end
