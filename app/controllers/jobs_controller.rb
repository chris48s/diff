class JobsController < ApplicationController
  def create
    @job = Job.new(url_1: params[:url_1], url_2: params[:url_2], status: 'pending', ip: request.remote_ip)
    if @job.save
      @job.generate_diff_async
      redirect_to job_path(@job)
    else
      error = {
        title: "Bad Request",
        details: @job.errors.full_messages
      }
      render json: error, status: 400
    end
  end

  def show
    @job = Job.find(params[:id])
  end
end